package output

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/mosajjal/dnsmonster/util"
	metrics "github.com/rcrowley/go-metrics"
	log "github.com/sirupsen/logrus"
)

type sqlConfig struct {
	SqlOutputType    uint          `long:"sqloutputtype"          ini-name:"sqloutputtype"          env:"DNSMONSTER_SQLOUTPUTTYPE"          default:"0"                                                       description:"What should be written to MySQL-compatibe database. options:\n;\t0: Disable Output\n;\t1: Enable Output without any filters\n;\t2: Enable Output and apply skipdomains logic\n;\t3: Enable Output and apply allowdomains logic\n;\t4: Enable Output and apply both skip and allow domains logic" choice:"0" choice:"1" choice:"2" choice:"3" choice:"4"`
	SqlEndpoint      string        `long:"sqlendpoint"            ini-name:"sqlendpoint"            env:"DNSMONSTER_SQLOUTPUTENDPOINT"      default:""                                                        description:"Sql endpoint used. must be in uri format. example: \"username:password@tcp(127.0.0.1:3306)/db_name\""`
	SqlWorkers       uint          `long:"sqlworkers"             ini-name:"sqlworkers"             env:"DNSMONSTER_SQLWORKERS"             default:"8"                                                       description:"Number of SQL workers"`
	SqlBatchSize     uint          `long:"sqlbatchsize"           ini-name:"sqlbatchsize"           env:"DNSMONSTER_SQLBATCHSIZE"           default:"1000"                                                    description:"Sql Batch Size"`
	SqlBatchDelay    time.Duration `long:"sqlbatchdelay"          ini-name:"sqlbatchdelay"          env:"DNSMONSTER_SQLBATCHDELAY"          default:"0s"                                                      description:"Interval between sending results to Sql if Batch size is not filled. Any value larger than zero takes precedence over Batch Size"`
	SqlBatchTimeout  time.Duration `long:"sqlbatchtimeout"        ini-name:"sqlbatchtimeout"        env:"DNSMONSTER_SQLBATCHTIMEOUT"        default:"5s"                                                      description:"Timeout for any INSERT operation before we consider them failed"`
	SqlSaveFullQuery bool          `long:"sqlsavefullquery"       ini-name:"sqlsavefullquery"       env:"DNSMONSTER_SQLSAVEFULLQUERY"       description:"Save full packet query and response in JSON format."`
	outputChannel    chan util.DNSResult
	outputMarshaller util.OutputMarshaller
	closeChannel     chan bool
}

func init() {
	c := sqlConfig{}
	if _, err := util.GlobalParser.AddGroup("sql_output", "SQL Output", &c); err != nil {
		log.Fatalf("error adding output Module")
	}
	c.outputChannel = make(chan util.DNSResult, util.GeneralFlags.ResultChannelSize)
	util.GlobalDispatchList = append(util.GlobalDispatchList, &c)
}

// initialize function should not block. otherwise the dispatcher will get stuck
func (sqConf sqlConfig) Initialize(ctx context.Context) error {
	var err error
	sqConf.outputMarshaller, _, err = util.OutputFormatToMarshaller("json", "")
	if err != nil {
		log.Warnf("Could not initialize output marshaller, removing output: %s", err)
		return err
	}

	if sqConf.SqlOutputType > 0 && sqConf.SqlOutputType < 5 {
		log.Info("Creating Sql Output Channel")
		go sqConf.Output(ctx)
	} else {
		// we will catch this error in the dispatch loop and remove any output from the registry if they don't have the correct output type
		return errors.New("no output")
	}
	return nil
}

func (sqConf sqlConfig) Close() {
	// todo: implement this
	<-sqConf.closeChannel
}

func (sqConf sqlConfig) OutputChannel() chan util.DNSResult {
	return sqConf.outputChannel
}

func (sqConf sqlConfig) connectSql() *sql.DB {

	db, err := sql.Open("mysql", sqConf.SqlEndpoint)
	db.SetConnMaxLifetime(time.Second * 10)
	if err != nil {
		// This will not be a connection error, but a DSN parse error or
		// another initialization error.
		log.Fatal(err)
	}
	// defer c.Close() // todo: move to a close channel
	err = db.Ping()
	if err != nil {
		log.Fatal(err)
	}

	_, err = db.Exec(
		`CREATE TABLE IF NOT EXISTS DNS_LOG (PacketTime timestamp, IndexTime timestamp,
				Server text, IPVersion integer, SrcIP binary(16), DstIP binary(16), Protocol char(3),
				QR smallint, OpCode smallint, Class int, Type integer, Edns0Present smallint,
				DoBit smallint, FullQuery text, ResponseCode smallint, Question text, Size smallint);`,
	)
	if err != nil {
		log.Error(err.Error())
	}

	return db
}

func (sqConf sqlConfig) Output(ctx context.Context) {
	for i := 0; i < int(sqConf.SqlWorkers); i++ {
		go sqConf.OutputWorker()
	}
}

func (sqConf sqlConfig) OutputWorker() {
	sqlSkipped := metrics.GetOrRegisterCounter("sqlSkipped", metrics.DefaultRegistry)
	sqlSentToOutput := metrics.GetOrRegisterCounter("sqlSentToOutput", metrics.DefaultRegistry)
	sqlFailed := metrics.GetOrRegisterCounter("sqlFailed", metrics.DefaultRegistry)

	c := uint(0)

	conn := sqConf.connectSql()

	ticker := time.NewTicker(time.Second * 5)
	div := 0
	if sqConf.SqlBatchDelay > 0 {
		sqConf.SqlBatchSize = 1
		div = -1
		ticker = time.NewTicker(sqConf.SqlBatchDelay)
	} else {
		ticker.Stop()
	}

	insertQuery := `INSERT INTO DNS_LOG(
		PacketTime, IndexTime, Server, IPVersion, SrcIP ,DstIP, Protocol, QR, OpCode,
		Class, Type, Edns0Present, DoBit, FullQuery, ResponseCode, Question, Size)
		VALUES `
	var insertStmt = insertQuery
	vals := []interface{}{}
	var stmt = new(sql.Stmt)
	var err error

	for {
		select {
		case data := <-sqConf.outputChannel:
			for _, dnsQuery := range data.DNS.Question {

				c++
				if util.CheckIfWeSkip(sqConf.SqlOutputType, dnsQuery.Name) {
					sqlSkipped.Inc(1)
					continue
				}

				fullQuery := ""
				if sqConf.SqlSaveFullQuery {
					fullQuery = sqConf.outputMarshaller.Marshal(data)
				}

				QR := uint8(0)
				if data.DNS.Response {
					QR = 1
				}
				edns, doBit := uint8(0), uint8(0)
				if edns0 := data.DNS.IsEdns0(); edns0 != nil {
					edns = 1
					if edns0.Do() {
						doBit = 1
					}
				}
				insertStmt += "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?),"
				vals = append(vals,
					data.Timestamp,
					time.Now(),
					util.GeneralFlags.ServerName,
					data.IPVersion,
					data.SrcIP.To16(),
					data.DstIP.To16(),
					data.Protocol,
					QR,
					uint8(data.DNS.Opcode),
					uint16(dnsQuery.Qclass),
					uint16(dnsQuery.Qtype),
					edns,
					doBit,
					fullQuery,
					uint8(data.DNS.Rcode),
					dnsQuery.Name,
					data.PacketLength,
				)

				if int(c%sqConf.SqlBatchSize) == div { // this block will never reach if batch delay is enabled
					//trim the last , prepare the statement
					stmt, err = conn.Prepare(strings.TrimSuffix(insertStmt, ","))
					if err != nil {
						log.Errorf("Error while preparing batch: %v", err)
						log.Infof("%+v, %d", vals, c)
						sqlFailed.Inc(int64(c))
					} else {
						// format all vals at once
						_, err = stmt.Exec(vals...)
						if err != nil {
							log.Errorf("Error while executing batch: %v", err)
							sqlFailed.Inc(int64(c))
						} else {
							sqlSentToOutput.Inc(int64(c))
						}
					}
					c = 0
					insertStmt = insertQuery
					vals = []interface{}{}
				}

			}
		case <-ticker.C:
			//trim the last , prepare the statement
			stmt, err := conn.Prepare(strings.TrimSuffix(insertStmt, ","))
			if err != nil {
				log.Errorf("Error while preparing batch: %v", err)
				sqlFailed.Inc(int64(c))
			} else {
				// format all vals at once
				_, err = stmt.Exec(vals...)
				if err != nil {
					log.Errorf("Error while executing batch: %v", err)
					sqlFailed.Inc(int64(c))
				} else {
					sqlSentToOutput.Inc(int64(c))
				}
			}
			c = 0
			insertStmt = insertQuery
			vals = []interface{}{}
		}
	}
}

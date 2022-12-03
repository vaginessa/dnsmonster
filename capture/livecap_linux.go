//go:build linux
// +build linux

package capture

import (
	"net/url"

	"github.com/gopacket/gopacket"
	"github.com/gopacket/gopacket/pcapgo"
	log "github.com/sirupsen/logrus"
)

type livePcapHandle struct {
	name       string
	readCnt    uint
	droppedCnt uint
	handle     *pcapgo.EthernetHandle
}

func (config captureConfig) initializeLivePcap(devName, filter string) *livePcapHandle {
	// Open device
	handle, err := pcapgo.NewEthernetHandle(devName)
	// handle, err := pcap.OpenLive(devName, 65536, true, pcap.BlockForever)
	if err != nil {
		log.Fatal(err)
	}
	err = handle.SetPromiscuous(!config.NoPromiscuous)
	if err != nil {
		log.Fatal("Error setting interface to promiscuous.. Exiting")
	}
	// Set Filter
	log.Infof("Using Device: %s", devName)
	bpf := tcpdumpToPcapgoBpf(filter)
	if bpf != nil {
		log.Infof("Filter: %s", filter)
		err = handle.SetBPF(bpf)
		if err != nil {
			log.Fatal(err)
		}
	}
	h := livePcapHandle{name: devName, handle: handle}
	return &h
}

func (h *livePcapHandle) ReadPacketData() (data []byte, ci gopacket.CaptureInfo, err error) {
	return h.handle.ReadPacketData()
}

func (h *livePcapHandle) ZeroCopyReadPacketData() (data []byte, ci gopacket.CaptureInfo, err error) {
	return h.handle.ZeroCopyReadPacketData()
}

func (h *livePcapHandle) Close() {
	h.handle.Close()
}
func (h *livePcapHandle) Name() string {
	return url.QueryEscape(h.name)
}

func (h *livePcapHandle) Stat() (uint, uint, error) {
	stats, err := h.handle.Stats()
	if err != nil {
		return 0, 0, err
	}
	h.readCnt += uint(stats.Packets)
	h.droppedCnt += uint(stats.Drops)
	return h.readCnt, h.droppedCnt, nil
}

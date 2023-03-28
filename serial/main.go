package main

import (
	"bytes"
	"encoding/binary"
	"flag"
	"fmt"
	"log"
	"net"
	"strconv"
)

type REQ struct {
	RandID       int64
	GuestUUID    [16]byte
	GuestID      int64
	IsReq        int32
	IsResp       int32
	NeedResponse int32
	ReqLength    int32
	RespLength   int32
	CommandID    int32
	SubCommand   int32
	Reserve      int32
}

var HostSN = flag.String("hostsn", "0000000000000", "Host SN, 13 bytes")
var GuestSN = flag.String("guestsn", "0000000000000", "Guest SN, 13 bytes")
var GuestUUID = flag.String("guestuuid", "ba13a19a-c0c1-4fef-9346-915ed3b98341", "Guest UUID")
var GuestCPUs = flag.Int("cpu", 1, "Num of Guest cpu")
var GuestCPU_ARCH = flag.String("cpu_arch", "QEMU, Virtual CPU, X86_64", "CPU arch")
var HostDSMBuildNumber = flag.Int("buildnumber", 42962, "Build Number of Host")
var HostDSMfixNumber = flag.Int("fixNumber", 0, "Fix Number of Host")
var VMMVersion = flag.String("vmmversion", "2.6.1-12139", "VMM version")
var VMMTimestamp = flag.Int("vmmts", 1679863686, "VMM Timestamp")
var Cluster_UUID = "3bdea92b-68f4-4fe9-aa4b-d645c3c63864"

var ListenAddr = flag.String("addr", "0.0.0.0:12345", "Listen address")

func main() {
	flag.Parse()

	listener, err := net.Listen("tcp", *ListenAddr)
	if err != nil {
		log.Println("Error listening", err.Error())
		return
	}
	log.Println("Start listen on " + *ListenAddr)

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Println("Error on accept", err.Error())
			return
		}
		log.Printf("New connection from %s\n", conn.RemoteAddr().String())
		go incoming_conn(conn)
	}
}

func incoming_conn(conn net.Conn) {
	for {
		buf := make([]byte, 4096)
		len, err := conn.Read(buf)
		if err != nil {
			log.Println("Error on read", err.Error())
			return
		}
		if len != 4096 {
			log.Printf("Read %d Bytes, not 4096\n", len)
			// something wrong, close and wait for reconnect
			conn.Close()
			return
		}
		go process_req(buf, conn)
		//log.Printf("Read %d Bytes\n%#v\n", len, string(buf[:len]))
	}
}

var commandsName = map[int]string{
	3:  "Guest Power info",
	4:  "Host DSM version",
	5:  "Guest SN",
	7:  "Guest CPU info",
	9:  "Host DSM version",
	8:  "VMM version",
	10: "Get Guest Info",
	11: "Guest UUID",
	12: "Cluster UUID",
	13: "Host SN",
	16: "Update Deadline",
	17: "Guest Timestamp",
}

func process_req(buf []byte, conn net.Conn) {
	var req REQ
	var data string
	err := binary.Read(bytes.NewReader(buf), binary.LittleEndian, &req)
	if err != nil {
		log.Printf("Error on decode %s\n", err)
		return
	}

	if req.IsReq == 1 {
		data = string(buf[64 : 64+req.ReqLength])
	} else if req.IsResp == 1 {
		data = string(buf[64 : 64+req.RespLength])
	}

	// log.Printf("%#v\n", req)
	log.Printf("Command: %s from Guest:%d \n", commandsName[int(req.CommandID)], req.GuestID)
	if data != "" {
		log.Printf("Info: %s\n", data)
	}
	// Hard code of command
	switch req.CommandID {
	case 3:
		// Guest start/reboot
	case 4:
		// Host DSM version
		data = fmt.Sprintf(`{"buildnumber":%d,"smallfixnumber":%d}`, *HostDSMBuildNumber, *HostDSMfixNumber)
	case 5:
		// Guest SN
		data = *GuestSN
	case 7:
		// CPU info
		// {"cpuinfo":"QEMU, Virtual CPU, X86_64, 1" "vcpu_num":1}
		data = fmt.Sprintf(`{"cpuinfo":"%s","vcpu_num":%d}`,
			*GuestCPU_ARCH+", "+strconv.Itoa(*GuestCPUs), *GuestCPUs)
	case 8:
		data = fmt.Sprintf(`{"id":"Virtualization","name":"Virtual Machine Manager","timestamp":%d,"version":"%s"}`,
			*VMMTimestamp, *VMMVersion)
	case 9:
		// Version Info
	case 10:
		// Guest Info
	case 11:
		// Guest UUID
		data = *GuestUUID
	case 12:
		// cluster UUID
		data = Cluster_UUID
	case 13:
		// Host SN
		data = *HostSN
	case 16:
		// Update Dead line time, always 0x7fffffffffffffff
		data = "9223372036854775807"
	case 17:
		// TimeStamp
	default:
		log.Printf("No handler for this command %d\n", req.CommandID)
		return
	}

	// if it's a req and need response
	if req.IsReq == 1 && req.NeedResponse == 1 {
		buf = make([]byte, 0, 4096)
		writer := bytes.NewBuffer(buf)
		req.IsResp = 1
		req.IsReq = 0
		req.ReqLength = 0
		req.RespLength = int32(len([]byte(data)) + 1)
		log.Printf("Response data: %s\n", data)

		// write to buf
		binary.Write(writer, binary.LittleEndian, &req)
		writer.Write([]byte(data))
		res := writer.Bytes()
		// full fill 4096
		buf = make([]byte, 4096, 4096)
		copy(buf, res)
		conn.Write(buf)
	}
}

// Test-only vehicle simulator. Uses official protobuf and FlatBuffers encoders.
package main

import (
    "crypto/tls"
    "crypto/x509"
    "encoding/json"
    "fmt"
    "net/http"
    "os"
    "path/filepath"
    "time"
    "github.com/gorilla/websocket"
    "github.com/teslamotors/fleet-telemetry/messages"
    "github.com/teslamotors/fleet-telemetry/messages/tesla"
    "github.com/teslamotors/fleet-telemetry/protos"
    "google.golang.org/protobuf/encoding/protojson"
    "google.golang.org/protobuf/proto"
)
func main() {
    dir, recordsFile := os.Args[1], os.Args[2]
    ca, err := os.ReadFile(filepath.Join(dir, "ca.pem")); must(err)
    roots := x509.NewCertPool(); if !roots.AppendCertsFromPEM(ca) { panic("invalid CA") }
    cfg := &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
    headers := http.Header{"Version": []string{"1.0.0"}}
    dialer := websocket.Dialer{TLSClientConfig: cfg, HandshakeTimeout: 10*time.Second}
    conn, _, err := dialer.Dial("wss://localhost:14443/", headers)
    if err == nil { conn.Close(); panic("receiver accepted missing client certificate") }
    cert, err := tls.LoadX509KeyPair(filepath.Join(dir,"client.pem"), filepath.Join(dir,"client-key.pem")); must(err)
    cfg.Certificates = []tls.Certificate{cert}
    conn, _, err = dialer.Dial("wss://localhost:14443/", headers); must(err); defer conn.Close()
    raw, err := os.ReadFile(recordsFile); must(err)
    var records []json.RawMessage; must(json.Unmarshal(raw, &records))
    vin := "LRW00000000000001"
    for i, raw := range records {
        p := &protos.Payload{}; must(protojson.Unmarshal(raw, p))
        data, err := proto.Marshal(p); must(err)
        id := []byte(fmt.Sprintf("smoke-%d", i))
        frame := tesla.FlatbuffersStreamToBytes([]byte("vehicle_device."+vin), []byte("V"), id, data, uint32(time.Now().Unix()), id, []byte("vehicle_device"), []byte(vin), 0)
        must(conn.SetWriteDeadline(time.Now().Add(30*time.Second)))
        must(conn.WriteMessage(websocket.BinaryMessage, frame))
        must(conn.SetReadDeadline(time.Now().Add(30*time.Second)))
        _, response, err := conn.ReadMessage(); must(err)
        ack, err := messages.StreamAckMessageFromBytes(response); must(err)
        if string(ack.TXID) != string(id) || ack.Topic() != "V" { panic("unexpected reliable ACK") }
    }
    fmt.Printf("mTLS rejection and %d reliable Kafka ACKs verified\n",len(records))
}
func must(err error) { if err != nil { panic(err) } }

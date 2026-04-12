package main

import "time"

type PingService struct{}

type PongReply struct {
	Pong int64 `json:"pong"`
}

func (p *PingService) Ping() PongReply {
	return PongReply{Pong: time.Now().UnixMilli()}
}

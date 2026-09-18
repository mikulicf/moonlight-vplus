package server

import (
	"embed"
	"io/fs"
	"net/http"
)

//go:embed web/*
var embeddedWeb embed.FS

func (s *Server) staticRoutes() {
	web, err := fs.Sub(embeddedWeb, "web")
	if err != nil {
		panic(err)
	}
	s.mux.Handle("GET /", http.FileServer(http.FS(web)))
}

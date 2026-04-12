package main

import (
	"embed"
	_ "embed"
	"log"

	"github.com/wailsapp/wails/v3/pkg/application"
)

//go:embed all:frontend/dist
var assets embed.FS

func main() {
	app := application.New(application.Options{
		Name:        "wails",
		Description: "Wails benchmark app",
		Services: []application.Service{
			application.NewService(&PingService{}),
		},
		Assets: application.AssetOptions{
			Handler: application.AssetFileServerFS(assets),
		},
		Mac: application.MacOptions{
			ApplicationShouldTerminateAfterLastWindowClosed: true,
		},
	})

	win := app.Window.NewWithOptions(application.WebviewWindowOptions{
		Title:  "Hello Wails",
		Width:  400,
		Height: 300,
		URL:    "/",
	})

	// Open devtools so bridge-bench.js can be pasted into the console.
	// On darwin, Wails v3's WKWebView has a custom context menu that
	// doesn't include "Inspect Element", so right-click doesn't work.
	// OpenDevTools() itself is a no-op in production builds (the
	// webview_window_darwin_production.go stub), so this only fires
	// when wails3 is invoked with DEV=true. For the benchmark, we
	// build wails that way — see scripts/build-all.sh.
	win.OpenDevTools()

	if err := app.Run(); err != nil {
		log.Fatal(err)
	}
}

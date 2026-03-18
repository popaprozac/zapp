import { Events } from "@zapp/backend";import { WindowHandle } from "@zapp/backend";import { App, Window } from "@zapp/backend";

console.log("[backend] starting");

App.configure({
    name: "Example App",
    applicationShouldTerminateAfterLastWindowClosed: true,
});

console.log("[backend] config:", App.getConfig());

const win: WindowHandle = await Window.create({
    title: "Window from Backend",
    width: 900,
    height: 600,
    x: 100,
    y: 100,
    visible: true,
});

const win2: WindowHandle = await Window.create({
    title: "Window from Backend 2",
    width: 900,
    height: 600,
    x: 100,
    y: 100,
    visible: true,
});

Events.on("window-ready", (data: any) => {
    console.log("[backend] window ready", data);
    console.log("[backend] window ready");
});

App.onReady(() => {
    console.log("[backend] ready");
});

console.log("[backend] created window:", win.id);

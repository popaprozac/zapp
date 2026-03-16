import { App, Window } from "@zapp/backend";

console.log("[backend] starting");

App.configure({
    name: "Example App",
    applicationShouldTerminateAfterLastWindowClosed: true,
});

console.log("[backend] config:", App.getConfig());

const win = await Window.create({
    title: "Window from Backend",
    width: 900,
    height: 600,
    x: 100,
    y: 100,
    visible: true,
});

const win2 = await Window.create({
    title: "Window from Backend 2",
    width: 900,
    height: 600,
    x: 100,
    y: 100,
    visible: true,
});

console.log("[backend] created window:", win.id);

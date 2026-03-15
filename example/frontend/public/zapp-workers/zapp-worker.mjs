function getZapp() {
	const z = globalThis.__zapp;
	if (!z) throw new Error("__zapp is unavailable. Is the bridge initialized?");
	return z;
}
const Event = {
	emit(name, payload) {
		return getZapp().emit(name, payload);
	},
	on(name, handler) {
		const off = getZapp().on(name, handler);
		return typeof off === "function" ? off : () => {};
	}
};
self.onmessage = (event) => {
	self.postMessage({
		type: "echo",
		payload: event.data
	});
};
await new Promise((resolve) => setTimeout(resolve, 5e3));
setInterval(() => {
	Event.emit("pong", { hello: "from-worker" });
}, 1e3);

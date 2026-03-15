(function() {
	function getZapp() {
		const z = globalThis.__zapp;
		if (!z) throw new Error("__zapp is unavailable. Is the bridge initialized?");
		return z;
	}
	const Events = {
		emit(name, payload) {
			return getZapp().emit(name, payload);
		},
		on(name, handler) {
			const off = getZapp().on(name, handler);
			return typeof off === "function" ? off : () => {};
		}
	};
	let id = Math.random();
	self.onmessage = async (event) => {
		console.log("echoing message", event.data);
		self.postMessage({
			type: "echo",
			payload: event.data
		});
	};
	self.receive("ping", (data) => {
		console.log("Worker received ping on channel", data);
		self.send("pong", {
			ok: true,
			orig: data
		});
	});
	Events.on("test", console.log);
	(async () => {
		try {
			const json = await (await fetch("https://jsonplaceholder.typicode.com/todos/1")).json();
			self.postMessage({
				type: "echo_with_fetch",
				payload: "hello",
				fetchResult: json,
				id
			});
		} catch (e) {
			console.error("Fetch failed", e);
		}
	})();
	let isChild = false;
	try {
		const child = new Worker(self.location.href);
		child.onmessage = (e) => {
			console.log("Parent worker received from child:", e.data);
		};
	} catch (e) {
		isChild = true;
		console.log("Reached worker depth limit or failed to spawn child:", e);
	}
	setInterval(() => {
		if (!isChild) console.log("emitting pong from parent worker");
		Events.emit("pong", {
			hello: isChild ? "from-child-worker" : "from-parent-worker",
			id
		});
	}, 1e3);
})();

(function() {
	self.onmessage = (event) => {
		self.postMessage({
			type: "echo",
			payload: event.data
		});
	};
})();

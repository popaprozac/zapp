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
export { Events as t };

// src/shared.ts
var sharedSelf = self;
sharedSelf.receive("ping", (data, reply) => {
  console.log("Shared worker received ping", data);
  reply("pong", { hello: "from-shared-worker" });
});
sharedSelf.onconnect = (e) => {
  console.log("Standard onconnect fired", e.ports);
};

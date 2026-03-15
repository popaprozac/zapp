// src/parity-shared.ts
var sharedSelf = self;
var zapp = sharedSelf.__zapp;
var connectCount = 0;
var eventCount = 0;
sharedSelf.receive("suite-shared-ping", (data, reply) => {
  reply("suite-shared-pong", {
    ok: true,
    payload: data,
    connectCount,
    eventCount
  });
});
sharedSelf.onconnect = () => {
  connectCount += 1;
};
zapp?.on?.("suite:backend-broadcast", () => {
  eventCount += 1;
});

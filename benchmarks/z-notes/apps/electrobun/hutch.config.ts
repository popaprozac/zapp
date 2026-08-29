export default {
  scripts: {
    install: ["hutch", "install", "--frozen-lockfile"],
    build: ["hutch", "electrobun", "build", "--env=stable"],
  },
  electrobun: {
    version: "2.0.1",
  },
};

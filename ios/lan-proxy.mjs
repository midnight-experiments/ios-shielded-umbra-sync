// Forwards TCP from this Mac's network to the module's API on loopback, so a phone on the same network can reach it:
//   node lan-proxy.mjs [listen port, default 10482] [target, default 127.0.0.1:10480]
// It listens on every interface for as long as it runs; stop it with Ctrl-C when the phone's run is done.
import { createServer, connect } from "node:net";
import { networkInterfaces } from "node:os";

const port = Number(process.argv[2] ?? 10482);
const [host, targetPort] = (process.argv[3] ?? "127.0.0.1:10480").split(":");
createServer((client) => {
  const upstream = connect(Number(targetPort), host);
  client.pipe(upstream).pipe(client);
  const close = () => { client.destroy(); upstream.destroy(); };
  client.on("error", close);
  upstream.on("error", close);
}).listen(port, "0.0.0.0", () => {
  const lan = Object.values(networkInterfaces()).flat().filter((a) => a && a.family === "IPv4" && !a.internal).map((a) => a.address);
  console.log(`forwarding :${port} → ${host}:${targetPort}; the phone's server URL: ${lan.map((a) => `http://${a}:${port}`).join(" or ")}`);
});

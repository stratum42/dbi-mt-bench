-- wrk Lua script: report exact p50, p95, p99 latencies in microseconds
done = function(summary, latency, requests)
  io.write(string.format(
    "LATENCY_US p50=%.2f p95=%.2f p99=%.2f avg=%.2f\n",
    latency:percentile(50.0),
    latency:percentile(95.0),
    latency:percentile(99.0),
    latency.mean
  ))
end

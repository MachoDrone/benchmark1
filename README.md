# Local Benchmark
You may wish to run benchmarks locally on your system as you are troubleshooting a problem, testing adjustments and upgrades, and to test your coolers.
This will lower your risk of driving your Host reputation into the ground.

This local benchmark test does not require a private-key and will not help you gain reputation, since it's not on-chain.

The current benchmark solution does not give any feedback while you are testing.
But this script will provide feedback and information.
This is a simple one-step command to run the full generic benchmarks. It takes a while, but you'll get a report at the end.
```wget -qO- https://raw.githubusercontent.com/MachoDrone/benchmark1/main/GenericBenchmark.sh | bash```

if the script complains that nodejs is not installed then run this script and it will install/update nodejs:
```sudo apt install nodejs npm -y && wget -qO- https://raw.githubusercontent.com/MachoDrone/benchmark1/main/GenericBenchmark.sh | bash```

https://github.com/MachoDrone
![screenshot](z1-Throttle.png)

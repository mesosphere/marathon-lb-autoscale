# marathon-lb-autoscale

This is an example of how to use marathon-lb to implement request rate based
autoscaling with Marathon. This should work with any application which uses
TCP traffic and can be routed through HAProxy.

Marathon-lb-autoscale will collect data from all HAProxy instances to determine
the current RPS (requests per second) for your apps. The autoscale controller
will then attempt to maintain a defined target number of requests per second
per app instance. Marathon-lb-autoscale will make API calls to Marathon to
scale the app.

![Incredible diagram](https://raw.github.com/mesosphere/marathon-lb-autoscale/master/marathon-lb-autoscale.png)

## How do I use it?

```
Usage: autoscale.rb [options]

Specific options:
        --marathon URL               URL for Marathon
        --haproxy [URLs]             Comma separate list of URLs for HAProxy. If this is a Mesos-DNS A-record, all backends will be polled.
        --interval Float             Number of seconds (N) between update intervals (Default: 60)
        --samples Integer            Number of samples to average (Default: 10)
        --cooldown Integer           Number of additional intervals to wait after making a scale change (Default: 5)
        --target-rps Float         Target number of requests per second per app instance (Default: 1000)
        --apps [APPS]                Comma separated list of <app>_<service port> pairs to monitor
        --marathonCredentials [MarathonCredentials]
                                     Colon separated string of <username>:<password>
        --haproxyCredentials [HAProxyCredentials]
                                     Colon separated string of <username>:<password>
        --threshold-percent Float    Scaling will occur when the target RPS differs from the current RPS by at least this amount (Default: 0.5)
        --threshold-instances Integer
                                     Scaling will occur when the target number of instances differs from the actual number by at least this amount (Default: 3)
        --max-instances Integer      Maximum number of instances an app may be scaled to (Default: a huge number)
        --min-instances Integer      Minimum number of instances an app must have (Default: 1)

Common options:
    -h, --help                       Show this message
```

## Running on Marathon

```json
{
  "id": "marathon-lb-autoscale",
  "args":[
    "--marathon", "http://leader.mesos:8080",
    "--haproxy", "http://marathon-lb.marathon.mesos:9090",
    "--apps", "nginx_10000"
  ],
  "cpus": 0.1,
  "mem": 16.0,
  "instances": 1,
  "container": {
    "type": "DOCKER",
    "docker": {
      "image": "mesosphere/marathon-lb-autoscale",
      "network": "HOST",
      "forcePullImage": true
    }
  }
}
```

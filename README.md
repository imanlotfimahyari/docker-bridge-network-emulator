# Docker Bridge Network Emulator

Bash-based network emulation tool for Docker bridge networks.

It applies Linux `tc` / `netem` rules on bridge-side veth interfaces to emulate per-container latency and bandwidth limits without modifying the application containers.

## What this project demonstrates

- Docker bridge and veth interface inspection
- Linux traffic control with `tc`
- Delay injection with `netem`
- Bandwidth shaping with HTB/CBQ
- Per-source traffic filtering
- Container-to-container network emulation

## Status

This is an experimental networking utility and portfolio project. It is useful for demonstrating Linux container networking and traffic-control concepts, but it is not currently packaged as a production-grade CLI.

## Requirements

- Linux host
- Docker
- Docker bridge networking
- `tc` / `iproute2`
- Root or sudo privileges

## Motivation
When multiple Docker containers are connected through a bridge network, it can be useful to emulate latency and bandwidth constraints between container pairs. This project applies Linux traffic-control using `tc`" [[1]](#1) rules on the host-side veth interfaces connected to the Docker bridge. This means the application containers do not need to be modified. The tool can emulate both delay and bandwidth constraints for traffic between containers.
If you have multiple Docker containers connected through a bridge, then using this sample script, you can modify the delays from one container to another with `Linux traffic controller (tc)`" [[1]](#1). This control is done inside the bridge and not from the inside of the containers, which is useful if you do not want to touch the containers. It is also possible to control the `Bandwidth` as well.

## Introduction
`CBQ` and `HTB` are two of the classful qdiscs in `tc`. `CBQ` (Class-Based Queueing) is a classful qdisc that implements a rich link-sharing hierarchy of classes. It contains shaping elements as well as prioritizing capabilities. Shaping is performed using link idle time calculations based on the timing of dequeue events and underlying link bandwidth" [[2]](#2). `HTB` is meant as a more understandable and intuitive replacement for the `CBQ` qdisc in Linux. Both `CBQ` and `HTB` help you to control the use of the outbound bandwidth on a given link. Both allow you to use one physical link to simulate several slower links and to send different kinds of traffic on different simulated links. In both cases, you have to specify how to divide the physical link into simulated links and how to decide which simulated link to use for a given packet to be sent. Unlike `CBQ`, `HTB` shapes traffic based on the `Token Bucket Filter` algorithm which does not depend on interface characteristics and so does not need to know the underlying bandwidth of the outgoing interface" [[3]](#3).

The control of the delay from `container A` towards `container B` can be done in `VethX` which connects the bridge to `container B` (destination container). So, for applying the different delays for data coming from different source containers, it is necessary to distinguish between the sources of the data in `VethX`. As every container has an IP address, this can be done by filtering the source IP address of the sender.

A simple structure with an internal view of `VethX` in a bridge and the containers is demonstrated here: 

<p align="middle">
  <img src="./delay1.png" width="300" height="250" />
  <img src="./delay2.png" width="300" height="250" /> 
</p>

## Schematic of classes, qdiscs, and filters
  ```bash
  #   (f) --<<          1:0            root handle 1:0 cbq|htb "qdisc"  
  #   (i) |              |                                           
  #   (l) |             1:1            classid 1:1 cbq|htb "class"
  #   (t) |            /   \
  #   (e) |           /     \
  #   (r) -->>     1:2      1:3   ...  leaf classes
  #                 |        |
  #                20:       30:  ...  leaf qdiscs
  #              (netem     (netem
  #              delay)     delay)
  ```

## Usage

You can use the scripts in two ways:

A. Create a test Docker bridge network

```bash
sudo ./DBDelay.sh test <container-count> <htb|cbq>
```

Example:

```bash
sudo ./DBDelay.sh test 3 htb
```

This creates a Docker network named `myTestBridge` using the bridge driver and starts containers named `client1` to `clientN`.

The script then asks for:

- The total inbound bandwidth allowed toward each destination container
- The bandwidth limit for each source-to-destination flow
- The delay for each source-to-destination flow

After testing, clean the generated structure:

```bash
sudo ./DBDelay.sh clean
```

B. Apply rules to an existing Docker bridge network

```bash
sudo ./DBDelay.sh modify <docker-network-name> [htb|cbq]
```

Example:

```bash
sudo ./DBDelay.sh modify my_existing_network htb
```

If no qdisc type is provided, the script defaults to `htb`.

To list Docker networks:

```bash
docker network ls
```

For this mode to work, the target containers must be directly attached to the selected Docker bridge network.

## Important notes

Use symmetric delays between each pair of containers if you want round-trip behavior to be predictable.

Also, make sure that the sum of per-flow bandwidth values assigned to a destination veth does not exceed the total bandwidth assigned to that veth.
  
## References
<a id="1">[1]</a> 
https://man7.org/linux/man-pages/man8/tc.8.html 
tc(8) — Linux manual page

<a id="2">[2]</a> 
https://man7.org/linux/man-pages/man8/tc-cbq-details.8.html. 
tc-cbq-details(8) — Linux manual page

<a id="3">[3]</a> 
http://luxik.cdi.cz/~devik/qos/htb/manual/userg.htm
HTB Linux queuing discipline manual - user guide.

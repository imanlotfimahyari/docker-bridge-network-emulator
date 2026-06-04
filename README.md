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
If you have multiple Docker containers connected together through a bridge, then using this sample script, you can modify the delays from one container to another with `Linux traffic controller (tc)`" [[1]](#1). This control is done inside the bridge and not from the inside of the containers, which is useful if you do not want to touch the containers. It is also possible to control the `Bandwidth` as well.

## Introduction
`CBQ` and `HTB` are two of the classful qdiscs in `tc`. `CBQ` (Class Based Queueing) is a classful qdisc that implements a rich link-sharing hierarchy of classes. It contains shaping elements as well as prioritizing capabilities. Shaping is performed using link idle time calculations based on the timing of dequeue events and underlying link bandwidth" [[2]](#2). `HTB` is meant as a more understandable and intuitive replacement for the `CBQ` qdisc in Linux. Both `CBQ` and `HTB` help you to control the use of the outbound bandwidth on a given link. Both allow you to use one physical link to simulate several slower links and to send different kinds of traffic on different simulated links. In both cases, you have to specify how to divide the physical link into simulated links and how to decide which simulated link to use for a given packet to be sent. Unlike `CBQ`, `HTB` shapes traffic based on the `Token Bucket Filter` algorithm which does not depend on interface characteristics and so does not need to know the underlying bandwidth of the outgoing interface" [[3]](#3).

The control of the delay from `container A` towards `container B` can be done in `VethX` which connects the bridge to `container B` (destination container). So, for applying the different delays for data coming from different source containers, it is needed to distinguish between the source of the data in `VethX`. As every container has an IP address, this can be done by filtering the source IP address of the sender.

A simple structure with an internal view of `VethX` in a bridge and the containers is demonstrated here: 

<p align="middle">
  <img src="./delay1.png" width="300" height="250" />
  <img src="./delay2.png" width="300" height="250" /> 
</p>

## Schematic of the structure of the classes, qdiscs and filters
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

## Using the script

You can use the scripts in two ways:

A. Starting a test structure using    
  ```bash
  sudo DBDelay.sh test X [cbq|htb]
  ```
  Where `X` is the desired number of the containers. This will build a network called `testNet` with a bridge named `myTestBridge` and the containers named `Client1` to `ClientX`.  It will ask for each container the total bandwidth it accepts from the bridge (through VethX), the delay, and the bandwidth regarding every other container towards this one.
  You need to select between `cbq` and `htb`.
  
  In this case, after finishing your tests, you can clean the test structure using
  ```bash
  sudo DBDelay.sh clean
  ``` 
B. Applying the script on an existing bridge. 
  1. Run the script as
  ```bash
  sudo DBDelay.sh modify BRIDGE_NAME
  ``` 
  Where ` BRIDGE_NAME` is the name of your bridge that you want to apply your desired delay and bandwidth control (use `docker network ls` in case you do not remember the bridge name). Similar to the first test network, it will ask for each container the total bandwidth it accepts from the bridge (through `VethX`), the delay, and the bandwidth regarding every other container towards this one. For this one to work, the containers must be directly connected to the bridge which is the target of this script.
  
  ## Important ##
  Do not forget to use symmetric delays between each pair of containers and keep in mind that the sum of the total bandwidth assigned to flows crossing `VethX` should not exceed the main bandwidth assigned to this `VethX`. Also, the sum of the total bandwidth in the bridge should be less than `1/10` of the available system bandwidth.
  
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

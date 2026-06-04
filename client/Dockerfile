FROM ubuntu:24.04

WORKDIR /work

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    iproute2 \
    iputils-ping \
    iperf3 \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

CMD ["/bin/bash"]

# Test image of the hardened fork: Debian 13 with the programs that the test
# suites need. tests/fork/run.sh builds it.
FROM debian:trixie
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      sudo php-cli iptables iproute2 procps unzip curl wget ca-certificates \
      shellcheck rsync python3 python3-pip python3-venv python3-dev build-essential \
      tshark ddclient jq \
 && rm -rf /var/lib/apt/lists/*
RUN id www-data > /dev/null 2>&1 || useradd -r www-data

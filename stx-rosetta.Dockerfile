### Build blockstack-core-sidecar API
FROM node:13.14.0-buster as build

ARG API_TAG=v0.28.0

RUN apt-get -y update && apt-get -y install openjdk-11-jre-headless

WORKDIR /app

RUN git clone -b $API_TAG --depth 1 https://github.com/blockstack/stacks-blockchain-api.git .
RUN echo "GIT_TAG=$(git tag --points-at HEAD)" >> .env
RUN npm install && npm run build && npm prune --production
# RUN npm config set unsafe-perm true && npm install --unsafe-perm
# RUN npm run build --unsafe-perm && npm prune --production

### Build stacks-node binary

FROM rust:stretch as stacks-node-build

ARG STACKS_TAG=v23.0.0.10-krypton

RUN mkdir -p /src /stacks
WORKDIR /src
RUN git clone -b $STACKS_TAG --depth 1 https://github.com/blockstack/stacks-blockchain.git .
RUN rustup target add x86_64-unknown-linux-gnu
RUN cargo build --release --workspace=./ --target x86_64-unknown-linux-gnu
RUN cp -R /src/target/x86_64-unknown-linux-gnu/release/. /stacks
RUN ls /stacks

### Fetch stacks-node binary

### Begin building base image
FROM ubuntu:focal

SHELL ["/bin/bash", "-c"]

### Install utils
RUN apt-get update
RUN apt-get install -y sudo curl pslist

### Set noninteractive apt-get
RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections

### Storage goes in /data; see https://www.rosetta-api.org/docs/standard_storage_location.html
RUN mkdir -p /data

### stacky user ###
# see https://docs.docker.com/develop/develop-images/dockerfile_best-practices/#user
RUN useradd -l -u 33333 -G sudo -md /data/stacky -s /bin/bash -p stacky stacky \
    # passwordless sudo for users in the 'sudo' group
    && sed -i.bkp -e 's/%sudo\s\+ALL=(ALL\(:ALL\)\?)\s\+ALL/%sudo ALL=NOPASSWD:ALL/g' /etc/sudoers
ENV HOME=/data/stacky
WORKDIR $HOME
USER stacky
RUN sudo chown -R stacky:stacky $HOME
RUN mkdir /data/stacky/.bashrc.d

### Node.js
# ENV NODE_VERSION=14.13.1
ENV NODE_VERSION=13.14.0
RUN curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.35.3/install.sh | bash \
    && bash -c ". .nvm/nvm.sh \
        && nvm install $NODE_VERSION \
        && nvm alias default $NODE_VERSION"
ENV PATH=$PATH:/data/stacky/.nvm/versions/node/v${NODE_VERSION}/bin
RUN node -e 'console.log("Node.js runs")'

### Setup stacks-node
COPY --from=stacks-node-build /stacks/stacks-node stacks-node/
ENV PATH="$PATH:$HOME/stacks-node"

#### Copy stacks-node mocknet config
COPY ./stacks-blockchain/Stacks-mocknet.toml ./

### Setup stacks-blockchain-api
COPY --from=build /app stacks-blockchain-api
RUN sudo chown -Rh stacky:stacky stacks-blockchain-api
RUN printf '#!/bin/bash\ncd $(dirname $0)\nnpm run start\n' > stacks-blockchain-api/stacks_api \
  && chmod +x stacks-blockchain-api/stacks_api
ENV PATH="$PATH:$HOME/stacks-blockchain-api"
EXPOSE 3999

### Install Postgres
RUN sudo apt-get install -y postgresql-12 postgresql-contrib-12

### Setup Postgres
# Borrowed from https://github.com/gitpod-io/workspace-images/blob/master/postgres/Dockerfile
ENV PATH="$PATH:/usr/lib/postgresql/12/bin"
ENV PGDATA="/data/stacky/.pgsql/data"
RUN mkdir -p ~/.pg_ctl/bin ~/.pg_ctl/sockets \
  && printf '#!/bin/bash\n[ ! -d $PGDATA ] && mkdir -p $PGDATA && initdb -D $PGDATA\npg_ctl -D $PGDATA -l ~/.pg_ctl/log -o "-k ~/.pg_ctl/sockets" start\n' > ~/.pg_ctl/bin/pg_start \
  && printf '#!/bin/bash\npg_ctl -D $PGDATA -l ~/.pg_ctl/log -o "-k ~/.pg_ctl/sockets" stop\n' > ~/.pg_ctl/bin/pg_stop \
  && chmod +x ~/.pg_ctl/bin/*
ENV PATH="$PATH:$HOME/.pg_ctl/bin"

### Clear caches
RUN sudo apt-get clean && sudo rm -rf /var/cache/apt/* /var/lib/apt/lists/* /tmp/*

### Setup service env vars
ENV PG_HOST=127.0.0.1
ENV PG_PORT=5432
ENV PG_USER=stacky
ENV PG_PASSWORD=postgres
ENV PG_DATABASE=postgres

ENV STACKS_CORE_EVENT_PORT=3700
ENV STACKS_CORE_EVENT_HOST=127.0.0.1

ENV STACKS_EVENT_OBSERVER=127.0.0.1:3700

ENV STACKS_BLOCKCHAIN_API_PORT=3999
ENV STACKS_BLOCKCHAIN_API_HOST=0.0.0.0

ENV STACKS_CORE_RPC_HOST=127.0.0.1
ENV STACKS_CORE_RPC_PORT=20443

### Startup script & coordinator
RUN printf '#!/bin/bash\n\
trap "exit" INT TERM\n\
trap "kill 0" EXIT\n\
echo Your container args are: "$@"\n\
tail --retry -F stacks-api.log stacks-node.log 2>&1 &\n\
while true\n\
do\n\
  pg_start\n\
  stacks_api &> stacks-api.log &\n\
  stacks_api_pid=$!\n\
  if [ $1 = "mocknet" ]; then\n\
    stacks-node start --config=/data/stacky/Stacks-mocknet.toml &> stacks-node.log &\n\
  else\n\
    stacks-node krypton &> stacks-node.log &\n\
  fi\n\
  stacks_node_pid=$!\n\
  wait $stacks_node_pid\n\
  echo "node exit, restarting..."\n\
  rkill -9 $stacks_api_pid\n\
  pg_stop\n\
  rm -rf $PGDATA\n\
  sleep 5\n\
done\n\
' >> run.sh && chmod +x run.sh

VOLUME /data

ENTRYPOINT ["/data/stacky/run.sh"]

CMD ["/data/stacky/run.sh"]
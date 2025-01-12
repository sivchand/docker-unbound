# syntax=docker/dockerfile:1.4

FROM alpine:3.18.4@sha256:eece025e432126ce23f223450a0326fbebde39cdf496a85d8c016293fc851978 AS build-base

ARG TARGETARCH

# hadolint ignore=DL3018
RUN --mount=type=cache,id=apk-cache-${TARGETARCH},target=/var/cache/apk \
    apk add --update --cache-dir=/var/cache/apk \
    binutils \
    bind-tools \
    build-base \
    ca-certificates-bundle \
    libevent-dev \
    libsodium-dev \
    openssl-dev \
    nghttp2-dev \
    expat-dev

ARG UNBOUND_UID=101
ARG UNBOUND_GID=102

RUN addgroup -g ${UNBOUND_GID} unbound \
    && adduser -u ${UNBOUND_UID} -D -H -G unbound unbound

# hadolint ignore=DL3007
FROM build-base AS ldns

WORKDIR /src

ARG LDNS_VERSION=1.8.4
# https://nlnetlabs.nl/downloads/ldns/ldns-1.8.3.tar.gz.sha256
ARG LDNS_SHA256="838b907594baaff1cd767e95466a7745998ae64bc74be038dccc62e2de2e4247"

ADD https://nlnetlabs.nl/downloads/ldns/ldns-${LDNS_VERSION}.tar.gz ldns.tar.gz

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN echo "${LDNS_SHA256}  ldns.tar.gz" | sha256sum -c - \
    && tar -xzf ldns.tar.gz --strip-components=1

RUN ./configure \
    --prefix=/opt/usr \
    --with-drill \
    --localstatedir=/var \
    --with-ssl \
    --disable-rpath \
    --disable-shared \
    --disable-static \
    --disable-ldns-config

RUN make -j"$(nproc)" && \
    make install && \
    strip /opt/usr/bin/drill && \
    ln -s drill /opt/usr/bin/dig

# hadolint ignore=DL3007
FROM build-base AS unbound

WORKDIR /src

ARG UNBOUND_VERSION=1.22.0
# https://nlnetlabs.nl/downloads/unbound/unbound-1.18.0.tar.gz.sha256
ARG UNBOUND_SHA256="c5dd1bdef5d5685b2cedb749158dd152c52d44f65529a34ac15cd88d4b1b3d43"

ADD https://nlnetlabs.nl/downloads/unbound/unbound-${UNBOUND_VERSION}.tar.gz unbound.tar.gz

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN echo "${UNBOUND_SHA256}  unbound.tar.gz" | sha256sum -c - \
    && tar -xzf unbound.tar.gz --strip-components=1

# https://unbound.docs.nlnetlabs.nl/en/latest/getting-started/installation.html#building-from-source-compiling
RUN ./configure \
    --prefix=/opt/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --disable-static \
    --disable-shared \
    --disable-rpath \
    --enable-dnscrypt \
    --enable-subnet \
    --with-pthreads \
    --with-libevent \
    --with-ssl \
    --with-libnghttp2 \
    --with-username=unbound

RUN make -j"$(nproc)" && \
    make install && \
    strip /opt/usr/sbin/unbound \
    /opt/usr/sbin/unbound-anchor \
    /opt/usr/sbin/unbound-checkconf \
    /opt/usr/sbin/unbound-control \
    /opt/usr/sbin/unbound-host

FROM scratch AS conf-example

# docker build . --target conf-example --output rootfs_overlay/etc/unbound/
COPY --from=unbound /etc/unbound/unbound.conf /unbound.conf.example

FROM scratch AS final

COPY --from=build-base /lib/ld-musl*.so.1 /lib/
COPY --from=build-base /usr/lib/libgcc_s.so.1 /usr/lib/
COPY --from=build-base /usr/lib/libnghttp2.so* /usr/lib/
COPY --from=build-base /lib/libcrypto.so.3 /lib/libssl.so.3 /lib/
COPY --from=build-base /usr/lib/libsodium.so.23 /usr/lib/libevent-2.1.so.7 /usr/lib/libexpat.so.1 /usr/lib/
COPY --from=build-base /etc/ssl/ /etc/ssl/
COPY --from=build-base /etc/passwd /etc/group /etc/

COPY --from=unbound /opt/usr/sbin/ /usr/sbin/

COPY --from=ldns /opt/usr/bin/ /usr/bin/

COPY --chown=unbound:unbound rootfs_overlay/ /
ADD --chown=unbound:unbound https://www.internic.net/domain/named.root /etc/unbound/root.hints
# TODO: run as non-root on port 5053
# USER unbound

RUN [ "unbound", "-V" ]
# hadolint ignore=DL3059
RUN [ "unbound-checkconf" ]    
# hadolint ignore=DL3059
RUN [ "drill", "-v" ]
# hadolint ignore=DL3059
RUN [ "dig", "-v" ]

ENTRYPOINT [ "unbound" ]

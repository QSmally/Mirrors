
FROM alpine AS compiler

ARG VERSION=0.16.0
ARG OPTIONS="-Doptimize=ReleaseFast"

RUN apk update && apk add curl tar xz

RUN curl https://ziglang.org/download/$VERSION/zig-$(uname -m)-linux-$VERSION.tar.xz -O && \
    tar -xf *.tar.xz && \
    mv zig-$(uname -m)-linux-$VERSION /compiler
WORKDIR /build

FROM compiler AS build

COPY build.zig build.zig.zon /build
COPY src /build/src
COPY zig /build/zig
RUN /compiler/zig build $OPTIONS

FROM alpine AS output
COPY --from=build /build/zig-out/bin /bin
EXPOSE 80

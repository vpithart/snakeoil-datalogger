FROM debian:13

RUN apt-get -y update
RUN apt-get -y install bash devscripts

RUN mkdir /data

WORKDIR /data
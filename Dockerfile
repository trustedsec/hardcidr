FROM kalilinux/kali-rolling

RUN apt update && apt upgrade -y
RUN apt install -y git ipcalc curl dnsutils ncat
RUN git clone https://github.com/trustedsec/hardcidr

WORKDIR hardcidr

ENTRYPOINT [ "./hardCIDR.sh" ]
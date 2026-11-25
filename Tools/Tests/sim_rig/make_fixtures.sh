#!/bin/bash
# Generates the throwaway TLS material and audio fixtures for the simulator rig.
set -euo pipefail

RIG="${1:?rig directory}"
mkdir -p "$RIG/audio"
cd "$RIG"

if [[ ! -f ca.pem || ! -f srv.pem ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem \
    -days 30 -subj "/CN=MeloX Local Test CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout srv.key -out srv.csr \
    -subj "/CN=localhost" 2>/dev/null
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\n' > ext.cnf
  openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
    -out srv.pem -days 30 -sha256 -extfile ext.cnf 2>/dev/null
fi

# One file per QQ encoding, named with QQ's own file prefix. Each is noise,
# independent per channel, at the level that gives the file the bitrate real
# files of its kind have on QQ: about 1 Mbps for FLAC, 3 for Hi-Res, 5.4 for
# the master, 0.9 for the stereo surround render and 2.3 for the 5.1 one.
make() {
  local name="$1" ext="$2" seconds="$3" rate="$4" channels="$5" level="$6"; shift 6
  [[ -f "audio/$name.$ext" ]] && return 0
  local inputs=() labels="" channel
  for ((channel = 0; channel < channels; channel++)); do
    inputs+=(-f lavfi -i "anoisesrc=d=$seconds:c=white:r=$rate:a=$level:seed=$((channel + 1))")
    labels+="[$channel:a]"
  done
  ffmpeg -y -v error "${inputs[@]}" \
    -filter_complex "${labels}amerge=inputs=$channels[mix]" -map "[mix]" \
    "$@" "audio/$name.$ext" </dev/null
}
make M500 mp3 90 44100 2 0.03 -b:a 128k
make M800 mp3 90 44100 2 0.03 -b:a 320k
make F000 flac 90 44100 2 0.038 -sample_fmt s16
make RS01 flac 90 96000 2 0.003 -sample_fmt s32
make AI00 flac 90 192000 2 0.001 -sample_fmt s32
make Q000 flac 90 48000 2 0.00004 -sample_fmt s32
make Q001 flac 90 48000 6 0.000015 -sample_fmt s32
# QQ's trial clip: a short MP3 handed out in place of the full song.
make RS02 mp3 20 44100 2 0.03 -b:a 128k

ls -la "$RIG" "$RIG/audio"

#!/bin/sh

#
# (c) 2010-2022 Cezary Jackiewicz <cezary@eko.one.pl>
#

band() {
	case "$1" in
		1) echo "${2}B1 (2100 MHz)";;
		3) echo "${2}B3 (1800 MHz)";;
		7) echo "${2}B7 (2600 MHz)";;
		8) echo "${2}B8 (900 MHz)";;
		20) echo "${2}B20 (800 MHz)";;
		*) echo "$1";;
	esac
}

RES="/usr/share/3ginfo-lite"

DEVICE=$(uci -q get 3ginfo.@3ginfo[0].device)
if [ "x$DEVICE" = "x" ]; then
	touch /tmp/modem
	DEVICE=$(cat /tmp/modem)
else
	echo "$DEVICE" > /tmp/modem
fi

if [ "x$DEVICE" = "x" ]; then
	devices=$(ls /dev/ttyUSB* /dev/cdc-wdm* /dev/ttyACM* /dev/ttyHS* 2>/dev/null | sort -r)
	for d in $devices; do
		DEVICE=$d gcom -s $RES/probeport.gcom > /dev/null 2>&1
		if [ $? = 0 ]; then
			echo "$d" > /tmp/modem
			break
		fi
	done
	DEVICE=$(cat /tmp/modem)
fi

if [ "x$DEVICE" = "x" ]; then
	echo '{"error":"Device not found"}'
	exit 0
fi

O=$(sms_tool -D -d $DEVICE at "AT+CSQ;+CPIN?;+COPS=3,0;+COPS?;+COPS=3,2;+COPS?;+CREG=2;+CREG?")

# CSQ
CSQ=$(echo "$O" | awk -F[,\ ] '/^\+(csq|CSQ)/ {print $2}')

[ "x$CSQ" = "x" ] && CSQ=-1
if [ $CSQ -ge 0 -a $CSQ -le 31 ]; then
	CSQ_PER=$(($CSQ * 100/31))
else
	CSQ="-"
	CSQ_PER=0
fi

# COPS numeric
COPS_NUM=$(echo "$O" | awk -F[\"] '/^\+COPS: .,2/ {print $2}')
if [ "x$COPS_NUM" = "x" ]; then
	COPS_NUM="-"
	COPS_MCC="-"
	COPS_MNC="-"
else
	COPS_MCC=${COPS_NUM:0:3}
	COPS_MNC=${COPS_NUM:3:3}
	COPS=$(awk -F[\;] '/'$COPS_NUM'/ {print $2}' $RES/mccmnc.dat)
fi
[ "x$COPS" = "x" ] && COPS=$COPS_NUM

if [ -z "$FORCE_PLMN" ]; then
	# COPS alphanumeric
	T=$(echo "$O" | awk -F[\"] '/^\+COPS: .,0/ {print $2}')
	[ "x$T" != "x" ] && COPS="$T"
fi

# CREG
eval $(echo "$O" | awk -F[,] '/^\+CREG/ {gsub(/[[:space:]"]+/,"");printf "T=\"%d\";LAC_HEX=\"%X\";CID_HEX=\"%X\";LAC_DEC=\"%d\";CID_DEC=\"%d\";MODE_NUM=\"%d\"", $2, "0x"$3, "0x"$4, "0x"$3, "0x"$4, $5}')
case "$T" in
	0*)
		REG="0"
		CSQ="-"
		CSQ_PER=0
		;;
	1*)
		REG="1"
		;;
	2*)
		REG="2"
		CSQ="-"
		CSQ_PER=0
		;;
	3*)
		REG="3"
		CSQ="-"
		CSQ_PER=0
		;;
	5*)
		REG="5"
		;;
	*)
		REG="-"
		CSQ="-"
		CSQ_PER=0
		;;
esac

# MODE
if [ -z "$MODE_NUM" ] || [ "x$MODE_NUM" = "x0" ]; then
	MODE_NUM=$(echo "$O" | awk -F[,] '/^\+COPS/ {print $4;exit}')
fi
case "$MODE_NUM" in
	2*) MODE="UMTS";;
	3*) MODE="EDGE";;
	4*) MODE="HSDPA";;
	5*) MODE="HSUPA";;
	6*) MODE="HSPA";;
	7*) MODE="LTE";;
	 *) MODE="-";;
esac

T=$(echo "$O" | awk -F[,\ ] '/^\+CME ERROR:/ {print $0;exit}')
if [ -n "$T" ]; then
	case "$T" in
	"+CME ERROR: 10"*) REG="SIM not inserted";;
	"+CME ERROR: 11"*) REG="SIM PIN required";;
	"+CME ERROR: 12"*) REG="SIM PUK required";;
	"+CME ERROR: 13"*) REG="SIM failure";;
	"+CME ERROR: 14"*) REG="SIM busy";;
	"+CME ERROR: 15"*) REG="SIM wrong";;
	"+CME ERROR: 17"*) REG="SIM PIN2 required";;
	"+CME ERROR: 18"*) REG="SIM PUK2 required";;
			*) REG=$(echo "$T" | cut -f2 -d: | xargs);;
	esac
fi

T=$(echo "$O" | awk -F[,\ ] '/^\+CPIN:/ {print $0;exit}' | xargs)
if [ -n "$T" ]; then
	[ "$T" = "+CPIN: READY" ] || REG=$(echo "$T" | cut -f2 -d: | xargs)
fi

_DEVS=$(awk '/Vendor=/{gsub(/.*Vendor=| ProdID=| Rev.*/,"");print}' /sys/kernel/debug/usb/devices | sort -u)
for _DEV in $_DEVS; do
	if [ -e "$RES/3ginfo-addon/$_DEV" ]; then
		case $(cat /tmp/sysinfo/board_name) in
		"zte,mf289f")
			. "$RES/3ginfo-addon/19d21485"
			;;
		*)
			. "$RES/3ginfo-addon/$_DEV"
			;;
		esac
		break
	fi
done

if [ "x$CSQ" = "x-" ] && [ "x$CSQ_PER" = "x0" ]; then
	MODE="-"
fi

cat <<EOF
{
"csq":"$CSQ",
"signal":"$CSQ_PER",
"operator_name":"$COPS",
"operator_mcc":"$COPS_MCC",
"operator_mnc":"$COPS_MNC",
"mode":"$MODE",
"registration":"$REG",
"lac_dec":"$LAC_DEC",
"lac_hex":"$LAC_HEX",
"cid_dec":"$CID_DEC",
"cid_hex":"$CID_HEX",
"addon":[$ADDON]
}
EOF
exit 0

#!bash

# The MIT License

# Copyright (c) 2022 John Siu

# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

declare -A BR
declare -A L2TP
declare -A NIC
declare -A PKG

DIR_BASE=$(dirname "$0")
DIR_OUT=${DIR_BASE}/out
DIR_SRC=${DIR_BASE}/src
MY_CONF=${DIR_BASE}/$(basename -s .sh "$0").conf.sample
SRV=''

cmd_exe() {
	echo "cmd: ${@}"
	${@}
}

__install_alpine() {
	if [ "${SRV}" != '' ]; then
		cmd_exe "scp -r ${DIR_OUT}/${SRV}/etc ${SRV}:/"
		if [ "${PKG[NAT]}" == 'true' ]; then
			cmd_exe "ssh ${SRV} /sbin/apk add iptables"
		fi
		if [ "${PKG[WIREGUARD]}" == 'true' ]; then
			cmd_exe "ssh ${SRV} /sbin/apk add wireguard-tools"
		fi
		if [ "${PKG[BRIDGE]}" == 'true' ]; then
			cmd_exe "ssh ${SRV} /sbin/apk add bridge bridge-utils"
		fi
		if [ "${PKG[L2TP]}" == 'true' ]; then
			cmd_exe "ssh ${SRV} chmod +x /etc/network/l2tp.sh"
		fi
	fi
}

__install_ubuntu() {
	if [ "${SRV}" != '' ]; then
		cmd_exe "scp -r ${DIR_OUT}/${SRV}/etc ${SRV}:/"
		if [ "${PKG[NAT]}" == 'true' ]; then
			cmd_exe "ssh ${SRV} apt -y install iptables"
		fi
		if [ "${PKG[WIREGUARD]}" == 'true' ]; then
			cmd_exe "ssh ${SRV} apt -y install wireguard-tools"
		fi
		if [ "${PKG[BRIDGE]}" == 'true' ]; then
			cmd_exe "ssh ${SRV} apt -y install bridge-utils"
		fi
		if [ "${PKG[L2TP]}" == 'true' ]; then
			cmd_exe "ssh ${SRV} chmod +x /etc/network/l2tp.sh"
		fi
	fi
}

__install() {
	__install_${OS}
}

__config_load() {
	if [ -f ${1} ]; then
		. ${1}
		echo Loaded ${1}
	else
		cp ${MY_CONF} ${1}
		echo "Please fill in ${1}"
	fi
}

__config_nat() {
	_d=${DIR_OUT}/${SRV}/etc/iptables
	_f=''

	case ${OS} in
	'alpine')
		_f=${_d}/rules-save
		;;
	*)
		_f=${_d}/rules.v4
		;;
	esac

	cmd_exe mkdir -p ${_d}
	echo '*nat' >${_f}
	echo ':PREROUTING ACCEPT [0:0]' >>${_f}
	echo ':INPUT ACCEPT [0:0]' >>${_f}
	echo ':OUTPUT ACCEPT [0:0]' >>${_f}
	echo ':POSTROUTING ACCEPT [0:0]' >>${_f}
	echo "[0:0] -A POSTROUTING -o ${NIC[1_IF]} -j SNAT --to-source ${NIC[1_IP]}" >>${_f}
	echo 'COMMIT' >>${_f}
}

__config_netplan() {
	echo
}

__config_netinterfaces() {

	_d=${DIR_OUT}/${SRV}/etc/network
	_f=${_d}/interfaces

	mkdir -p ${_d}

	echo 'auto lo' >${_f}
	echo "iface lo inet loopback" >>${_f}
	echo >>${_f}

	_c=1
	while [ "${NIC[${_c}_IF]}" != '' ]; do

		# NIC
		echo "auto ${NIC[${_c}_IF]}" >>${_f}
		echo "iface ${NIC[${_c}_IF]} inet ${NIC[${_c}_MODE]}" >>${_f}
		if [ "${NIC[${_c}_IP]}" != '' ]; then
			echo "address ${NIC[${_c}_IP]}" >>${_f}
		fi
		if [ "${NIC[${_c}_NM]}" != '' ]; then
			echo "netmask ${NIC[${_c}_NM]}" >>${_f}
		fi
		if [ "${NIC[${_c}_GW]}" != '' ]; then
			echo "gateway ${NIC[${_c}_GW]}" >>${_f}
		fi
		if [ "${NIC[${_c}_DNS]}" != '' ]; then
			echo "dns-nameservers ${NIC[${_c}_DNS]}" >>${_f}
		fi
		if [ "${NIC[${_c}_NAT]}" == 'true' ]; then
			PKG[NAT]=true
			echo "post-up /sbin/iptables -t nat -A POSTROUTING -o ${NIC[${_c}_IF]} -j SNAT --to-source ${NIC[${_c}_IP]}" >>${_f}
		fi
		echo >>${_f}

		# Wireguard
		if [ "${PKG[WIREGUARD]}" == 'true' ]; then
			if [ "${NIC[${_c}_IF]}" == "${WG_REQ}" ]; then
				echo "auto ${WG_IF}" >>${_f}
				echo "iface ${WG_IF} inet static" >>${_f}
				echo "address ${WG_ADDR}" >>${_f}
				echo "requires ${WG_REQ}" >>${_f}
				echo "pre-up ip link add ${WG_IF} type wireguard" >>${_f}
				echo "pre-up wg setconf ${WG_IF} /etc/wireguard/${WG_IF}.conf" >>${_f}
				echo "post-down ip link del ${WG_IF}" >>${_f}
				echo >>${_f}
			fi
		fi

		((_c++))
	done

	# Bridge
	if [ "${PKG[BRIDGE]}" == 'true' ]; then
		_c=1
		while [ "${BR[${_c}_IF]}" != '' ]; do
			echo "auto ${BR[${_c}_IF]}" >>${_f}
			echo "iface ${BR[${_c}_IF]} inet ${BR[${_c}_MODE]}" >>${_f}
			if [ "${BR[${_c}_PREUP]}" != '' ]; then
				echo "pre-up ${BR[${_c}_PREUP]}" >>${_f}
			fi
			if [ "${BR[${_c}_REQ]}" != '' ]; then
				echo "requires ${BR[${_c}_REQ]}" >>${_f}
			fi
			if [ "${BR[${_c}_PORTS]}" != '' ]; then
				echo "bridge-ports ${BR[${_c}_PORTS]}" >>${_f}
			fi
			if [ "${BR[${_c}_IP]}" != '' ]; then
				echo "address ${BR[${_c}_IP]}" >>${_f}
			fi
			if [ "${BR[${_c}_NM]}" != '' ]; then
				echo "netmask ${BR[${_c}_NM]}" >>${_f}
			fi
			if [ "${BR[${_c}_GW]}" != '' ]; then
				echo "gateway ${BR[${_c}_GW]}" >>${_f}
			fi
			_c=$(($_c + 1))
		done
	fi
}

__config_l2tp() {
	_d=${DIR_OUT}/${SRV}/etc/network
	_f=${_d}/l2tp.sh
	mkdir -p ${_d}

	_c=1
	while [ "${L2TP[${_c}_IF]}" != '' ]; do
		echo "ip l2tp add tunnel tunnel_id ${L2TP[${_c}_TID]} peer_tunnel_id ${L2TP[${_c}_PTID]} encap udp local ${L2TP[${_c}_ADDRL]} remote ${L2TP[${_c}_ADDRR]} udp_sport ${L2TP[${_c}_SPORT]} udp_dport ${L2TP[${_c}_DPORT]}" >>${_f}
		echo "ip l2tp add session tunnel_id ${L2TP[${_c}_TID]} session_id ${L2TP[${_c}_SID]} peer_session_id ${L2TP[${_c}_PSID]}" >>${_f}
		((_c++))
	done

	chmod +x ${_f}
}

__config_wireguard() {
	_d=${DIR_OUT}/${SRV}/etc/wireguard
	_f=${_d}/${WG_IF}.conf
	mkdir -p ${_d}
	echo '[Interface]' >${_f}
	#echo "Address = ${WG_ADDR}" >>${_f}
	echo "ListenPort = ${WG_PORT}" >>${_f}
	echo "PrivateKey = ${WG_KEY_PRI}" >>${_f}
	echo '[Peer]' >>${_f}
	echo "PublicKey = ${WG_KEY_PUB}" >>${_f}
	echo "AllowedIPs = ${WG_ALLOWED_IP}" >>${_f}
	if [ "${WG_ENDPOINT}" != '' ]; then
		echo "Endpoint = ${WG_ENDPOINT}" >>${_f}
	fi
}

__dir_prep() {
	_r=${1}
	if [ "${SRV}" != '' ]; then
		_d=${DIR_OUT}/${SRV}
		rm -rf ${_d}
		mkdir -p ${_d}
		cp -r ${DIR_SRC}/* ${_d}/
	fi
}

__dir_copy() {
	echo
}

# $1: config file
main() {
	_f=${1}
	__config_load ${_f}
	__dir_prep ${R_NUM}

	for p in L2TP NETINTERFACES NETPLAN WIREGUARD; do
		if [ "${PKG[${p}]}" == 'true' ]; then
			cmd_exe "__config_${p,,}"
		fi
	done

	__install
}

for i in ${@}; do
	cmd_exe main ${i}
done

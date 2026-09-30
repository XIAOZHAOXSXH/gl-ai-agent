#!/bin/sh
# Probe real RPC method signatures on the router (defensive: never fails hard).
# Usage: sh rpc-probe.sh
RPC=http://127.0.0.1/rpc
call() {
    obj="$1"; meth="$2"; args="$3"
    echo "----- $obj.$meth  args=$args"
    printf '%s' "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":[\"\",\"$obj\",\"$meth\",$args],\"id\":1}" > /tmp/p.json
    curl -s -H "glinet:1" -X POST "$RPC" --data-binary @/tmp/p.json | head -c 700
    echo
}

call wifi get_status '{}'
call wifi get_config '{}'
call clients get_status '{}'
call clients get_list '{}'
call system get_info '{}'
call system get_load '{}'
call network get_status '{}'
call network get_netnat_config '{}'
call dns get_config '{}'
call timer get_wifi '{}'
call firewall get_port_forward_list '{}'
call firewall get_wan_access '{}'
call repeater get_saved_ap_list '{}'
call logread get_system_log '{"lines":5}'
call system get_timezone_config '{}'
rm -f /tmp/p.json
echo "===== END ====="

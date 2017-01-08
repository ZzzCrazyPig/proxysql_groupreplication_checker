#!/bin/bash
#
# author: CrazyPig
# date: 2017-01-07
# version: 1.0

function usage() {
  echo "Usage: $0 <hostgroup_id write> <hostgroup_id read> [write node can be read : 1(YES: default) or 0(NO)] [log_file]"
  exit 0
}

if [ "$1" = '-h' -o "$1" = '--help' ] || [ -z "$1" -o -z "$2" ]; then
  usage
fi

# receive input arg
writeGroupId="${1:-1}"
readGroupId="${2:-2}"
writeNodeCanRead="${3:-1}"
errFile="${4:-"./checker.log"}"

# variable define
proxysql_user="admin"
proxysql_password="admin"
proxysql_host="127.0.0.1"
proxysql_port="6032"

switchOver=0
timeout=3

# enable(1) debug info or not(0)
debug=1
function debug() {
  local appendToFile="${2:-0}"
  local msg="[`date \"+%Y-%m-%d %H:%M:%S\"`] $1"
  if [ $debug -eq 1 ]; then
    echo $msg
  fi
  if [ $appendToFile -eq 1 ]; then
    echo $msg >> $errFile
  fi
}

debug "writeGroupId : $writeGroupId, readGroupId : $readGroupId, writeNodeCanRead : $writeNodeCanRead, errFile : $errFile"
proxysql_cmd="mysql -u$proxysql_user -p$proxysql_password -h$proxysql_host -P$proxysql_port -Nse"
debug "proxysql_cmd : $proxysql_cmd"
mysql_credentials=$($proxysql_cmd "SELECT variable_value FROM global_variables WHERE variable_name IN ('mysql-monitor_username','mysql-monitor_password') ORDER BY variable_name DESC")
mysql_user=$(echo $mysql_credentials | awk '{print $1}')
mysql_password=$(echo $mysql_credentials | awk '{print $2}')
debug "mysql_user : $mysql_user, mysql_password : $mysql_password"
mysql_cmd="mysql -u$mysql_user -p$mysql_password"
debug "mysql_cmd : $mysql_cmd"

update_servers_cmd_opts="LOAD MYSQL SERVERS TO RUNTIME; SAVE MYSQL SERVERS TO DISK;"

# check node status is OK or not
function isNodeOk() {
  local gr_status=$1
  local trx_behind=$2
  debug "gr_status : $gr_status, trx_behind : $trx_behind"
  if [ "$gr_status" == "YES" ]; then
    return 1
  elif [ "$gr_status" == "" -o "$gr_status" == "NO" ]; then
    return 0
  fi
}

# main logic

# find current write node
read cwn_hostname cwn_port <<< $($proxysql_cmd "SELECT hostname,port FROM mysql_servers WHERE hostgroup_id = $writeGroupId LIMIT 1;")
debug "current write node hostname : ${cwn_hostname}, port : ${cwn_port}"
# for every read node in read hostgroup
output=$($proxysql_cmd "SELECT hostgroup_id, hostname, port, status FROM mysql_servers WHERE hostgroup_id = $readGroupId;" 2>> $errFile)
while read hostgroup_id hostname port status
do
  # check node is ok
  read gr_status trx_behind <<< $(timeout $timeout $mysql_cmd -h$hostname -P$port -Nse "SELECT viable_candidate, transactions_behind FROM sys.gr_member_routing_candidate_status" 2>>$errFile | tail -1 2>>$errFile) 
  isNodeOk $gr_status $trx_behind
  isOK=$?
  debug "node [hostgroup_id: $hostgroup_id, hostname: $hostname, port: $port, status: $status, isOK: $isOK ]"
  # node is current write node
  if [ "$hostname" == "$cwn_hostname" -a "$port" == "$cwn_port" ]; then
    debug "node is the current write node"
    if [ $isOK -eq 0 ]; then
      # need to find new write node
      switchOver=1
      debug "current write node [hostgroup_id: $hostgroup_id, hostname: $hostname, port: $port, isOK: $isOK] is not OK, we need to do switch over" 1
      $proxysql_cmd "UPDATE mysql_servers SET status = 'OFFLINE_SOFT' WHERE hostgroup_id = $readGroupId AND hostname = '$hostname' AND port = $port; ${update_servers_cmd_opts}" 2>> $errFile
      $proxysql_cmd "UPDATE mysql_servers SET status = 'OFFLINE_HARD' WHERE hostgroup_id = $writeGroupId AND hostname = '$cwn_hostname' AND port = $cwn_port; ${update_servers_cmd_opts}" 2>> $errFile
    else # isOK = 1
      if [ $writeNodeCanRead -eq 0 ]; then # write node can not be read
        debug "isOK : $isOK, write node can not be read, will update node status to OFFLINE_SOFT [hostgroup_id: $readGroupId, hostname: $hostname, port: $port]"
        $proxysql_cmd "UPDATE mysql_servers SET status = 'OFFLINE_SOFT' WHERE hostgroup_id = $readGroupId AND hostname = '$hostname' AND port = $port; ${update_servers_cmd_opts}" 2>> $errFile
      else
        if [ "$status" != "ONLINE" ]; then
          debug "isOK : $isOK, write node can be read, will update node status to ONLINE [hostgroup_id: $readGroupId, hostname: $hostname, port: $port]"
          $proxysql_cmd "UPDATE mysql_servers SET status = 'ONLINE' WHERE hostgroup_id = $writeGroupId AND hostname = '$hostname' AND port = $port; ${update_servers_cmd_opts}" 2>> $errFile
          $proxysql_cmd "UPDATE mysql_servers SET status = 'ONLINE' WHERE hostgroup_id = $readGroupId AND hostname = '$hostname' AND port = $port; ${update_servers_cmd_opts}" 2>> $errFile
        fi
      fi
    fi
  # node is not current write node and status is not OK
  elif [ $isOK -eq 0 ]; then
    debug "read node [hostgroup_id: $hostgroup_id, hostname: $hostname, port: $port, isOK: $isOK] is not OK, we will set it's status to be 'OFFLINE_SOFT'" 1
    $proxysql_cmd "UPDATE mysql_servers SET status = 'OFFLINE_SOFT' WHERE hostgroup_id = $readGroupId AND hostname = '$hostname' AND port = $port; ${update_servers_cmd_opts}" 2>> $errFile
  elif [ $isOK -eq 1 -a "$status" == "OFFLINE_SOFT" ]; then
    debug "read node [hostgroup_id: $hostgroup_id, hostname: $hostname, port: $port, isOK: $isOK] is OK, but is's status is 'OFFLINE_SOFT', we will update it to be 'ONLINE' 1"
    $proxysql_cmd "UPDATE mysql_servers SET status = 'ONLINE' WHERE hostgroup_id = $readGroupId AND hostname = '$hostname' AND port = $port; ${update_servers_cmd_opts}" 2>> $errFile
  fi
done <<EOF
$output
EOF

if [ $switchOver -eq 1 ]; then
  debug "now we will select one normal node from read hostgroup to be the new node ..." 1
  read nwn_hostname nwn_port <<< $($proxysql_cmd "SELECT hostname, port FROM mysql_servers WHERE hostgroup_id = $readGroupId AND status = 'ONLINE' LIMIT 1;" 2>> $errFile)
  if [ "$nwn_hostname" != "" ]; then
    debug "find new write node from read hostgroup, [hostgroup_id: $readGroupId, hostname : $nwn_hostname, port : $nwn_port]" 1
    $proxysql_cmd "UPDATE mysql_servers SET hostname = '$nwn_hostname', port = $nwn_port, status = 'ONLINE' WHERE hostgroup_id = $writeGroupId; ${update_servers_cmd_opts}" 2>> $errFile
    if [ $writeNodeCanRead -eq 0 ]; then
      $proxysql_cmd "UPDATE mysql_servers SET status = 'OFFLINE_SOFT' WHERE hostgroup_id = $readGroupId AND hostname = '$nwn_hostname' AND port = $nwn_port; ${update_servers_cmd_opts}" 2>> $errFile
    fi
  else
    debug "from read hostgroup, we can not find new node to be write node" 1
  fi
fi

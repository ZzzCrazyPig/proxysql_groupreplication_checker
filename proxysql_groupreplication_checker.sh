#!/bin/bash
## inspired by proxysql_galera_checker.sh 
# Author: Frédéric -lefred- Descamps
# version: 0.1
# 2016-08-25

# CHANGE THOSE
PROXYSQL_USERNAME="admin"
PROXYSQL_PASSWORD="admin"
PROXYSQL_HOSTNAME="127.0.0.1"
PROXYSQL_PORT="6032"
#

function usage()
{
  echo "Usage: $0 <hostgroup_id write> [hostgroup_id read] [number writers] [writers are readers 0|1} [log_file]"
  exit 0
}

if [ "$1" = '-h' -o "$1" = '--help'  -o -z "$1" ]
then
  usage
fi

if [ $# -lt 1 ]
then
  echo "Invalid number of arguments"
  usage
fi

HOSTGROUP_WRITER_ID="${1}"
HOSTGROUP_READER_ID="${2:--1}"
NUMBER_WRITERS="${3:-0}"
WRITER_IS_READER="${4:-1}"
ERR_FILE="${5:-/dev/null}"

#echo "Hostgroup writers $HOSTGROUP_WRITER_ID"
#echo "Hostgroup readers $HOSTGROUP_READER_ID"
#echo "Number of writers $NUMBER_WRITERS"
#echo "Writers are readers $WRITER_IS_READER"
#echo "log file $ERR_FILE"

#Timeout exists for instances where mysqld may be hung
TIMEOUT=10

PROXYSQL_CMDLINE="mysql -u$PROXYSQL_USERNAME -p$PROXYSQL_PASSWORD -h $PROXYSQL_HOSTNAME -P $PROXYSQL_PORT --protocol=tcp -Nse"
MYSQL_CREDENTIALS=$($PROXYSQL_CMDLINE "SELECT variable_value FROM global_variables WHERE variable_name IN ('mysql-monitor_username','mysql-monitor_password') ORDER BY variable_name DESC")
MYSQL_USERNAME=$(echo $MYSQL_CREDENTIALS | awk '{print $1}')
MYSQL_PASSWORD=$(echo $MYSQL_CREDENTIALS | awk '{print $2}')
#echo $MYSQL_CREDENTIALS
#echo $MYSQL_USERNAME $MYSQL_PASSWORD
MYSQL_CMDLINE="timeout $TIMEOUT mysql -u$MYSQL_USERNAME -p$MYSQL_PASSWORD "

$PROXYSQL_CMDLINE "SELECT hostgroup_id, hostname, port, status, max_replication_lag FROM mysql_servers WHERE hostgroup_id IN ($HOSTGROUP_WRITER_ID, $HOSTGROUP_READER_ID) AND status <> 'OFFLINE_HARD'" | while read hostgroup server port stat max_replication_lag
do
  read GR_STATUS READONLY TRX_BEHIND <<<$($MYSQL_CMDLINE -h $server -P $port -Nse "SELECT viable_candidate, read_only,transactions_behind FROM sys.gr_member_routing_candidate_status")
  echo "`date` Check server $hostgroup:$server:$port , status $stat , GR_STATUS $GR_STATUS, READONLY $READONLY, TRX_BEHIND $TRX_BEHIND" >> ${ERR_FILE}
  if [ "${GR_STATUS}" == "YES" -a "${READONLY}" == "NO" -a "$stat" != "ONLINE" -a ${TRX_BEHIND} -le $max_replication_lag ] ; then
    echo "`date` Changing server $hostgroup:$server:$port to status ONLINE" >> ${ERR_FILE}
    $PROXYSQL_CMDLINE "UPDATE mysql_servers SET status='ONLINE' WHERE hostgroup_id=$hostgroup AND hostname='$server' AND port='$port';" 2>> ${ERR_FILE}
  elif [ "${GR_STATUS}" == "YES" -a "${READONLY}" == "YES" -a "$stat" != "ONLINE" -a "$hostgroup" == "$HOSTGROUP_READER_ID" -a ${TRX_BEHIND} -le $max_replication_lag ] ; then
    echo "`date` Changing server $hostgroup:$server:$port to status ONLINE" >> ${ERR_FILE}
    $PROXYSQL_CMDLINE "UPDATE mysql_servers SET status='ONLINE' WHERE hostgroup_id=$hostgroup AND hostname='$server' AND port='$port';" 2>> ${ERR_FILE}
  elif [ "${GR_STATUS}" ==  "NO" -o "${READONLY}" == "YES" -a "$stat" = "ONLINE" -a "$hostgroup" == "$HOSTGROUP_WRITER_ID" ] ; then
    echo "`date` Changing server $hostgroup:$server:$port to status OFFLINE_SOFT" >> ${ERR_FILE}
    $PROXYSQL_CMDLINE "UPDATE mysql_servers SET status='OFFLINE_SOFT' WHERE hostgroup_id=$hostgroup AND hostname='$server' AND port='$port';" 2>> ${ERR_FILE}
  elif [ "${GR_STATUS}" == "YES" -a "${READONLY}" == "NO" -a "$stat" = "ONLINE" -a ${TRX_BEHIND} -gt $max_replication_lag ] ; then
    echo "`date` Changing server $hostgroup:$server:$port to status OFFLINE_SOFT" >> ${ERR_FILE}
    $PROXYSQL_CMDLINE "UPDATE mysql_servers SET status='OFFLINE_SOFT' WHERE hostgroup_id=$hostgroup AND hostname='$server' AND port='$port';" 2>> ${ERR_FILE}
  fi
done

if [ $NUMBER_WRITERS -gt 0 ]
then
  CONT=0
  # Only check online servers
  $PROXYSQL_CMDLINE "SELECT hostname, port FROM mysql_servers WHERE hostgroup_id = $HOSTGROUP_WRITER_ID AND status = 'ONLINE' order by hostname, port" | while read server port
  do
    if [ $CONT -ge $NUMBER_WRITERS ]
    then
      # Number of writers reached, disabling extra servers
      echo "`date` Number of writers reached, disabling extra write server $HOSTGROUP_WRITER_ID:$server:$port to status OFFLINE_SOFT" >> ${ERR_FILE}
      $PROXYSQL_CMDLINE "UPDATE mysql_servers set status = 'OFFLINE_SOFT' WHERE hostgroup_id = $HOSTGROUP_WRITER_ID AND hostname = '$server' AND port = $port;" 2>> ${ERR_FILE}
    fi
    CONT=$(( $CONT + 1 ))
  done
fi

if [ $WRITER_IS_READER -eq 0 ]
then
  # Writer is not a read node, but only if we have another read node online
  READER_NON_WRITER=$($PROXYSQL_CMDLINE "SELECT count(*) FROM mysql_servers ms1 LEFT JOIN mysql_servers ms2 ON ms1.hostname = ms2.hostname AND ms1.port = ms2.port AND ms1.hostgroup_id <> ms2.hostgroup_id WHERE ms1.hostgroup_id = $HOSTGROUP_READER_ID AND ms1.status = 'ONLINE' AND (ms2.hostgroup_id = $HOSTGROUP_WRITER_ID OR ms2.hostgroup_id IS NULL) AND (ms2.status = 'OFFLINE_SOFT' OR ms2.hostgroup_id IS NULL);" 2>>${ERR_FILE})
  if [ $READER_NON_WRITER -gt 0 ]
  then
    $PROXYSQL_CMDLINE "SELECT hostname, port FROM mysql_servers WHERE hostgroup_id = $HOSTGROUP_WRITER_ID AND status = 'ONLINE' order by hostname, port" | while read server port
    do
      echo "`date` Disabling read for write server $HOSTGROUP_READER_ID:$server:$port to status OFFLINE_SOFT" >> ${ERR_FILE}
      $PROXYSQL_CMDLINE "UPDATE mysql_servers set status = 'OFFLINE_SOFT' WHERE hostgroup_id = $HOSTGROUP_READER_ID AND hostname = '$server' AND port = $port;" 2>> ${ERR_FILE}
    done
  else
    echo "`date` Not enough read servers, we won't disable read in write servers" >> ${ERR_FILE}
  fi
fi

echo "`date` Enabling config" >> ${ERR_FILE}
$PROXYSQL_CMDLINE "LOAD MYSQL SERVERS TO RUNTIME;" 2>> ${ERR_FILE}

exit 0

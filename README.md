# Introduction

According to the blog [HA with MySQL Group Replication and ProxySQL](http://lefred.be/content/ha-with-mysql-group-replication-and-proxysql/), we can use ProxySQL to make HA with MySQL Group Replication(MGR), and even we can realize Read-Write split above it. This project provides several shell scripts to be used in ProxySQL scheduler in order to meet the function we memtion.

## proxysql_groupreplication_checker.sh

This script is an example of scheduler that can be used with ProxySQL to monitor MySQL Group Replication members

Modify from : [https://github.com/lefred/proxysql_groupreplication_checker](https://github.com/lefred/proxysql_groupreplication_checker)

### Features and Limitations

#### Features

- Read-Write split
- Multi Write node
- Automatic switch over when write node fail

#### Limitations

- MGR must run in multi-primary mode

In general, we just need one write node and other node to be read, and we need to adapt MGR two mode: Multi-Primary Mode and Single-Primary Mode, so the scripts below come into the world.

## gr_mw_mode_sw_cheker.sh

This script is using for monitoring MySQL Group Replication in **Multi-Primary Mode**, and we limit **there is only one node to be write node at a time.**

### Features and Limitations

#### Features

- Read-Write split
- Automatic switch over when single write node fail

#### Limitations

- MGR must run in multi-primary Mode
- Only one node to be write node at a time

### Configuration

Assume that we have one MGR group with 3 node deploy in multi-primary mode:

```sql
mysql> SELECT * FROM performance_schema.replication_group_members;
+---------------------------+--------------------------------------+-------------+-------------+--------------+
| CHANNEL_NAME              | MEMBER_ID                            | MEMBER_HOST | MEMBER_PORT | MEMBER_STATE |
+---------------------------+--------------------------------------+-------------+-------------+--------------+
| group_replication_applier | 4a48f63a-d47b-11e6-a16f-a434d920fb4d | CrazyPig-PC |       24801 | ONLINE       |
| group_replication_applier | 592b4ea5-d47b-11e6-a3cd-a434d920fb4d | CrazyPig-PC |       24802 | ONLINE       |
| group_replication_applier | 6610aa92-d47b-11e6-a60e-a434d920fb4d | CrazyPig-PC |       24803 | ONLINE       |
+---------------------------+--------------------------------------+-------------+-------------+--------------+
3 rows in set (0.00 sec)
```

and we have deployed ProxySQL(version 1.3.2) correctly on one same machine.

Now we need to config MGR and ProxySQL to act together :

**1) let ProxySQL have the privilege to connect and SELECT something from MGR members**

In all MGR members, execute:

```sql
set SQL_LOG_BIN=0;
grant SELECT on *.* to 'proxysql'@'%' identified by 'proxysql';
flush privileges;
set SET SQL_LOG_BIN=1;
```

**2) create custom function and view in MGR members**

According to [https://github.com/lefred/mysql_gr_routing_check/blob/master/addition_to_sys.sql](https://github.com/lefred/mysql_gr_routing_check/blob/master/addition_to_sys.sql), execute the sql in all of the MGR members.

> Tip: we will use the custom function and view in the shell script.

**3) config proxysql**

Add MGR members to proyxsql `mysql_servers` table:

```sql
insert into mysql_servers (hostgroup_id, hostname, port) values(1, '127.0.0.1', 24801);
insert into mysql_servers (hostgroup_id, hostname, port) values(2, '127.0.0.1', 24801);
insert into mysql_servers (hostgroup_id, hostname, port) values(2, '127.0.0.1', 24802);
insert into mysql_servers (hostgroup_id, hostname, port) values(2, '127.0.0.1', 24803);
```

`hostgroup_id = 1` represent the write group, and we have only one write node at a time, `hostgroup_id = 2` represent the read group and it includes all the MGR members.

It’s time to add some routing rules to be able to use those hostgroups:

```sql
insert into mysql_query_rules (active, match_pattern, destination_hostgroup, apply) 
values (1,"^SELECT",2,1);
```

We will route all queries starting by select to hostgroup which hostgroup_id is 2.

> This is not a recommendation of course a we will also send to hostgroup 2 all SELECT… FOR UPDATE, for example

And then we need to change the default proxysql monitor user and password we create in **step 1)**

```sql
UPDATE global_variables SET variable_value='proxysql' WHERE variable_name='mysql-monitor_username';
UPDATE global_variables SET variable_value='proxysql' WHERE variable_name='mysql-monitor_password';
```

Finally we can load `global_variables`, `mysql_servers`, `mysql_query_rules` to runtime and even to disk:

```sql
LOAD MYSQL VARIABLES TO RUNTIME;
SAVE MYSQL VARIABLES TO DISK;
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;
LOAD MYSQL QUERY RULES TO RUNTIME;
SAVE MYSQL QUERY RULES TO DISK;
```

**4) config scheduler**

First, put the script `gr_mw_mode_sw_cheker.sh` to path : `/var/lib/proxysql/`

Finally, we just need to config our script into proxysql scheduler and load it to runtime and even save to disk:

```sql
insert into scheduler(id, active, interval_ms, filename, arg1, arg2, arg3, arg4)
  values(1, 1, 5000, '/var/lib/proxysql/gr_mw_mode_sw_checker.sh', 1, 2, 1, '/var/lib/proxysql/checker.log');

LOAD SCHEDULER TO RUNTIME;
SAVE SCHEDULER TO DISK;
```

- *active* : 1: enable scheduler to schedule the script we provide
- *interval_ms* : invoke one by one in cycle (eg: 5000(ms) = 5s represent every 5s invoke the script)
- *filename*: represent the script file path
- *arg1~arg4*: represent the input parameters the script received

The script Usage:

```bash
gr_mw_mode_sw_cheker.sh writehostgroup_id readhostgroup_id [writeNodeCanRead] [log file]
```

So :

- *arg1* -> writehostgroup_id
- *arg2* -> readhostgroup_id
- *arg3* -> writeNodeCanRead, 1(YES, the default value), 0(NO)
- *arg4* -> log file, default: `'./checker.log'`

## gr_sw_mode_checker.sh

This script is using for monitoring MySQL Group Replication in **Single-Primary Mode**, so the limit is also : **there is only one node to be write node at a time.**

### Features and Limitations

#### Features

- Read-Write split
- Switch over automatic when single write node failure

#### Limitations

- MGR(MySQL Group Replication) run in single-primary Mode
- Only one node to be write node at a time

### Configuration

the same configuration step as [gr_mw_mode_sw_cheker.sh](https://github.com/ZzzCrazyPig/proxysql_groupreplication_checker#gr_mw_mode_sw_cheker.sh), just in **step 4)**, replace the script with `gr_sw_mode_cheker.sh`

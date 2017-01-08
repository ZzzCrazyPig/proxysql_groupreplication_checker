# 介绍

利用ProxySQL可以为MySQL Group Replication(后面简称MGR) 提供高可用及读写分离方案。这个项目里面主要提供了几个可以被ProxySQL scheduler调度，用于监控MGR成员状态，实现MGR高可用，读写分离且写故障切换功能的脚本。

## proxysql_groupreplication_checker.sh

用于监控MySQL Group Replication成员状态的示例shell脚本。只提供了读写分离功能，但是没有提供写节点故障切换功能。

修改自 : [https://github.com/lefred/proxysql_groupreplication_checker](https://github.com/lefred/proxysql_groupreplication_checker)

> Tip: 后面脚本的设计灵感来自这个示例脚本，在实现读写分离功能的基础上，实现写节点故障自动切换功能。

## gr_mw_mode_sw_cheker.sh

实现Multi-Primary Mode下的MySQL Group Replication高可用和读写分离的脚本，限制只能有一个节点用于写。

### 特性和限制

#### 特性

- 读写分离
- 写节点故障自动切换

#### 限制

- MGR必须部署于Multi-Primary Mode
- 只有一个节点用于写

### 配置方式

假设我们已经部署了一个3节点组成的MGR集群，模式为Multi-Primary：

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

并且，已经成功的在同一台机器上部署了ProxySQL(version 1.3.2)，并成功运行。

现在我们需要配置MGR和ProxySQL，让它们能够共同协作，实现高可用和读写分离:

**1) MGR节点创建ProxySQL能够连接和执行SELECT操作的用户**

在所有的MGR节点上，执行:

```sql
set SQL_LOG_BIN=0;
grant SELECT on *.* to 'proxysql'@'%' identified by 'proxysql';
flush privileges;
set SET SQL_LOG_BIN=1;
```

**2) MGR节点创建定制的自定义函数和视图**

这些自定义函数和视图会被脚本所使用，提供MGR节点状态的相关指标。在所有的MGR节点上执行[https://github.com/lefred/mysql_gr_routing_check/blob/master/addition_to_sys.sql](https://github.com/lefred/mysql_gr_routing_check/blob/master/addition_to_sys.sql)提供的脚本。

**3) 配置proxysql**

将MGR节点信息写入proxysql `mysql_servers`表:

```sql
insert into mysql_servers (hostgroup_id, hostname, port) values(1, '127.0.0.1', 24801);
insert into mysql_servers (hostgroup_id, hostname, port) values(2, '127.0.0.1', 24801);
insert into mysql_servers (hostgroup_id, hostname, port) values(2, '127.0.0.1', 24802);
insert into mysql_servers (hostgroup_id, hostname, port) values(2, '127.0.0.1', 24803);
```

`hostgroup_id = 1`代表write group，针对我们提出的限制，这个地方只配置了一个节点；`hostgroup_id = 2`代表read group，包含了MGR的所有节点。

接下来我们需要修改proxysql的监控用户和密码为我们上面 **step 1)** 提供的用户和密码。

```sql
UPDATE global_variables SET variable_value='proxysql' WHERE variable_name='mysql-monitor_username';
UPDATE global_variables SET variable_value='proxysql' WHERE variable_name='mysql-monitor_password';
```

最后我们需要将`global_variables`和`mysql_servers`表的信息加载到RUNTIME，更进一步加载到DISK:

```sql
LOAD MYSQL VARIABLES TO RUNTIME;
SAVE MYSQL VARIABLES TO DISK;
LOAD MYSQL SERVERS TO RUNTIME;
SAVE MYSQL SERVERS TO DISK;
```

**4) 配置scheduler**

首先，将我们提供的脚本`gr_mw_mode_sw_cheker.sh`放到目录`/var/lib/proxysql/`下

最后，我们在proxysql的scheduler表里面加载如下记录，然后加载到RUNTIME使其生效，同时还可以持久化到磁盘:

```sql
insert into scheduler(id, active, interval_ms, filename, arg1, arg2, arg3, arg4)
  values(1, 1, 5000, '/var/lib/proxysql/gr_mw_mode_sw_checker.sh', 1, 2, 1, '/var/lib/proxysql/checker.log');

LOAD SCHEDULER TO RUNTIME;
SAVE SCHEDULER TO DISK;
```

- *active* : 1: 表示使脚本调度生效
- *interval_ms* : 每隔多长时间执行一次脚本 (eg: 5000(ms) = 5s 表示每隔5s脚本被调用一次)
- *filename*: 指定脚本所在的具体路径，如上面的`/var/lib/proxysql/checker.log`
- *arg1~arg4*: 指定传递给脚本的参数

脚本及对应的参数说明如下:

```bash
gr_mw_mode_sw_cheker.sh writehostgroup_id readhostgroup_id [writeNodeCanRead] [log file]
```

- *arg1* -> 指定writehostgroup_id
- *arg2* -> 指定readhostgroup_id
- *arg3* -> 写节点是否可以用于读, 1(YES, the default value), 0(NO)
- *arg4* -> log file, default: `'./checker.log'`

## gr_sw_mode_checker.sh

实现Single-Primary Mode下的MySQL Group Replication高可用和读写分离的脚本，限制只能有一个节点用于写。

### 特性与限制

#### 特性

- 读写分离
- 写节点故障自动切换

#### 限制

- MGR必须部署在Single-Primary模式
- 同一时间只有一个节点用于写

### 配置方式

与上一个脚本`gr_mw_mode_sw_cheker.sh`的部署方式基本一致，只是在 **step 4)** 中将脚本替换为`gr_sw_mode_checker.sh`

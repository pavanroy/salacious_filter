#!/bin/bash
set -e

# Roy Marupally - pmarup@acxiom.com

# Script for salacious hack.

CONS_NA_POOL=hudson
BLOCKSIZE=1073741824
COMPRESSION_CODEC=org.apache.hadoop.io.compress.GzipCodec


MAILING_LIST=pmarup@acxiom.com

f () {
errcode=$? 

v1="Error "
v2=$errcode
v3=" the command executing at the time of the error was " 
v4=$BASH_COMMAND
v5=" on line "
v6=${BASH_LINENO[0]}
v7="$v1 $v2 $v3 $v4 $v5 $v6"
echo "
$v7" >> nohup.out

mail -s "HHLINK Build: cons na hack failure" $MAILING_LIST < nohup.out
exit $errcode  
}
trap f ERR

cat /dev/null > nohup.out

if [ -d "/hdfs/hhlink/cons_hack/salacious_temp" ]; then
hadoop fs -rm -r /hhlink/cons_hack/salacious_temp
fi

hadoop jar /usr/lib/hadoop-0.20-mapreduce/contrib/streaming/hadoop-streaming.jar \
-D dfs.block.size=$BLOCKSIZE  \
-D mapred.reduce.tasks=0 \
-D mapred.fairscheduler.pool=$CONS_NA_POOL \
-D mapred.output.compress=true \
-D mapred.output.compression.codec=$COMPRESSION_CODEC \
-D mapred.job.name="hhlink hack: profanity filter" \
-input /Abilitec/Cons_NA/Mar2016/part* \
-output /hhlink/cons_hack/salacious_temp \
-mapper hadoop_profanity_hack.pl \
-file hadoop_profanity_hack.pl \
-file base_profanity_list.txt

if [ -d "/hdfs/hhlink/cons_hack/salacious_detail" ]; then
hadoop fs -rm -r /hhlink/cons_hack/salacious_detail
fi

if [ -d "/hdfs/hhlink/cons_hack/salacious_output" ]; then
hadoop fs -rm -r /hhlink/cons_hack/salacious_output
fi

pig -F split_salacious.pig

mail -s "HHLINK Build: cons na hack successful" $MAILING_LIST < nohup.out

cat /dev/null > nohup.out
-- split salacious debugging details from output

set output.compression.enabled true;
set output.compression.codec org.apache.hadoop.io.compress.GzipCodec;
set pig.tmpfilecompression true;
set pig.tmpfilecompression.codec gz;
set mapred.fairscheduler.pool 'hudson';
set job.name 'split salacious';
SET default_parallel 100;

salacious_output = load '/hhlink/cons_hack/salacious_temp/part*' using PigStorage(',')as (reason:chararray,ock:chararray,code:chararray);

detail_temp = FILTER salacious_output BY (reason == 'detail');
output_temp = FILTER salacious_output BY (reason == 'output');

final_out = foreach output_temp generate ock,code;

STORE detail_temp INTO '/hhlink/cons_hack/salacious_detail' USING PigStorage(',');
STORE final_out INTO '/hhlink/cons_hack/salacious_output' USING PigStorage(',');
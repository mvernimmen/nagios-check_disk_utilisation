#!/bin/sh
#
# This is a plugin for nagios/opsview/omd to measure disk throughput related statistics.
# 20160901 mve total rewrite so that it's much faster and more accurate. No longer using awk
# 20160902 mve bugfixes and support for multiple disks in a system.
# 20160905 mve prevent check from returning negative numbers when counters wrap or upon reboot.


function help {
echo -e "
This plugin shows the I/O usage of the specified disk, by doing a similar
calculation that iostat does but over a flexible timeframe. It needs to store
temporary data to do this.
It prints three statistics: Transactions per second (tps), Kilobytes per second
read from the disk (KB_read/s) and written to the disk (KB_written/s)

$0:\n
-d <disk>\t\tDevice to be checked (without the full path, eg. sda)
-c <tps>,<read>,<wrtn>\tSets the CRITICAL level for tps, KB_read/s and KB_written/s, respectively
-w <tps>,<read>,<wrtn>\tSets the WARNING level for tps, KB_read/s and KB_written/s, respectively\n"
        exit -1
}

# support floating point devisions without the need for awk or bc or dc
div ()  # Arguments: dividend and divisor
{
        if [ $2 -eq 0 ]; then echo division by 0; exit; fi
        local p=12                            # precision
        local c=${c:-0}                       # precision counter
        local d=.                             # decimal separator
        local r=$(($1/$2)); echo -n $r        # result of division
        local m=$(($r*$2))
        [ $c -eq 0 ] && [ $m -ne $1 ] && echo -n $d
        [ $1 -eq $m ] || [ $c -eq $p ] && return
        local e=$(($1-$m))
        let c=c+1
        div $(($e*10)) $2
}

# Getting parameters:
while getopts "d:w:c:h" OPT; do
        case $OPT in
                "d") disk=$OPTARG;;
                "w") warning=$OPTARG;;
                "c") critical=$OPTARG;;
                "h") help;;
        esac
done

persistentStatsFile="/tmp/nagios_check_disk_extended2.stat.${disk}"

# Adjusting the three warn and crit levels:
crit_tps=`echo $critical | cut -d, -f1`
crit_read=`echo $critical | cut -d, -f2`
crit_written=`echo $critical | cut -d, -f3`

warn_tps=`echo $warning | cut -d, -f1`
warn_read=`echo $warning | cut -d, -f2`
warn_written=`echo $warning | cut -d, -f3`


# Checking parameters:
[ ! -b "/dev/$disk" ] && echo "ERROR: Device incorrectly specified" && help

( [ "$warn_tps" == "" ] || [ "$warn_read" == "" ] || [ "$warn_written" == "" ] || \
  [ "$crit_tps" == "" ] || [ "$crit_read" == "" ] || [ "$crit_written" == "" ] ) &&
        echo "ERROR: You must specify all warning and critical levels" && help

( [[ "$warn_tps" -ge  "$crit_tps" ]] || \
  [[ "$warn_read" -ge  "$crit_read" ]] || \
  [[ "$warn_written" -ge  "$crit_written" ]] ) && \
  echo "ERROR: critical levels must be highter than warning levels" && help

# Get stats
# time in seconds since epoch without summer/winter time changes that can cause weird effects.
time_now=$(TZ=UTC0 printf '%(%s)T\n' '-1')

# Do we have data from a previous run?
if [ -s ${persistentStatsFile} ]; then
  # get the old values
  # timestamp
  OIFS="$IFS"
  IFS=':' read -a line <<< $( cat ${persistentStatsFile} );
  time_prev=${line[0]}
  tps_prev=${line[1]}
  kbread_prev=${line[2]}
  kbwritten_prev=${line[3]}
  weightedIOtime_prev=${line[4]}
else
  # use 0's
  time_prev=$(( ${time_now} - 1 ))
  tps_prev=0
  kbread_prev=0
  kbwritten_prev=0
  weightedIOtime_prev=0
  firstrun=1
fi

# debug
#echo "now: ${time_now} prev: ${time_prev}"

# Get current data from /sys/block/<disk>/stats
read c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 < /sys/block/${disk}/stat
tpsR_cur=$c2
tpsW_cur=$c6
tps_cur=$(( $tpsR_cur + $tpsW_cur ))
sector_size=$(cat /sys/block/sda/queue/hw_sector_size)
kbread_cur=$(( $c3 * ${sector_size} ))
kbwritten_cur=$(( $c7 * ${sector_size} ))
weightedIOtime_cur=$c10

# debug
#echo "kbread_prev: ${kbread_prev} kbread_cur: ${kbread_cur} (c3: ${c3} sect_size: ${sector_size})time_prev: ${time_prev} time_now: ${time_now}"

# calculate the delta's based on current and previous values:
deltatime=$(( $time_now - $time_prev ))
# If the check is called within a second, currently can't handle that. exit.
if [ ${deltatime} -eq 0 ]; then exit 1;fi

# store current data for the next run only if we're atleast a second apart
echo "${time_now}:${tps_cur}:${kbread_cur}:${kbwritten_cur}:${weightedIOtime_cur}" > ${persistentStatsFile};

# Calculate the metrics to return to 'nagios' (difference between now and previous run)
dividend=$(( $tps_cur - $tps_prev ))
tps=$(div $dividend  $deltatime)
dividend=$(( ${kbread_cur} - ${kbread_prev} ))
devider=$(($deltatime * 1024 ))
kbread=$(div $dividend $devider)
dividend=$(( ${kbwritten_cur} - ${kbwritten_prev} ))
devider=$(($deltatime * 1024 ))
kbwritten=$(div $dividend $devider)
dividend=$(( ($weightedIOtime_cur - $weightedIOtime_prev ) * 100 ))
devider=$((${deltatime} * 1000 ))
utilpct=$(div $dividend $devider)

# debug
#echo "tps_prev :${tps_prev} tps_cur: ${tps_cur} deltatime: ${deltatime} tps: ${tps}"

#bash can't do floating point mathematics and we don't have bc by default, so strip the . and all after it using sed. Everyone has sed, right?
atps="$(echo $tps | sed 's/\([0-9]\+\)\..*/\1/')"
akbread="$(echo $kbread | sed 's/\([0-9]\+\)\..*/\1/')"
akbwritten="$(echo $kbwritten | sed 's/\([0-9]\+\)\..*/\1/')"
autilpct="$(echo ${utilpct} | sed 's/\([0-9]\+\)\..*/\1/')"

# Prevent negative numbers
[ ${atps} -lt 0 ] && tps=0
[ ${akbread} -lt 0 ] && kbread=0
[ ${akbwritten} -lt 0 ] && kbwritten=0
[ ${autilpct} -lt 0 ] && utilpct=0

if ( [ $atps -ge $crit_tps ] || [ $akbread -ge $crit_read ] || [ $akbwritten -ge $crit_written ] ); then
        msg="CRITICAL"
        status=2
elif ( [ $atps -ge $warn_tps ] || [ $akbread -ge $warn_read ] || [ $akbwritten -ge $warn_written ] ); then
        msg="WARNING"
        status=1
else
    msg="OK"
    status=0
fi

# Printing the results:
if [[ $firstrun -eq 1 ]]; then
  echo "$msg - I/O stats tps=0 KB_read/s=0 KB_written/s=0 %io-utilisation=0 | 'tps'=0; 'KB_read/s'=0; 'KB_written/s'=0; 'io-utilisation'=0;"
else
  # use printf so we can format the floating point numbers.
  printf "$msg - I/O stats tps=%.1f KB_read/s=%.1f KB_written/s=%.1f %%io-utilisation=%.1f | 'tps'=%.1f; 'KB_read/s'=%.1f; 'KB_written/s'=%.1f; 'io-utilisation'=%.1f;\n" $tps $kbread $kbwritten $utilpct $tps $kbread $kbwritten $utilpct
fi
# Bye!
exit $status


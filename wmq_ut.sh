#!/bin/bash

#
# Copyright (C) 2009,2010 Sergey V. Udaltsov <sergey.udaltsov@gmail.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA
#

#
# Description: Run WMQMB unit tests
#
# Parameters: subset of tests. If empty, all tests are being run
#
# Configuration: wmq_ut.conf (in the current directory) or $UT_CONFIG 
#
# Configuration file variables:
#
#   Global:
#     componentName (mandatory) - the name of the component being tested
#     queueManager (mandatory) - the queue manager
#     broker (mandatory) - the broker name
#     inputQueue (mandatory) - the input queue name
#     executionGroup (optional) - the broker execution group, default 'default'
#     testTimeout (optional) - the time to wait after sending the message, default 10
#     brokerTraceLevel (optional) - the trace level, default 'normal'
#     oracleDb (optional) - the Oracle connection, user/password@db
#     ignoreXmlElements (optional) - the XML elements to ignore (date/time/machine id/...)
#
#   Per-test:
#     testDescription[i] (mandatory) - the description of the test
#     testInputQueue[i] (mandatory) - the input queue 
#                                     (if different from the global)
#     testOutputQueues[i] (optional) - the list of output queues. One queue 
#                                      can be listed several times if several
#                                      messages are expected
#     testEmptyQueues[i] (optional) - the list of empty queues.
#     testOutputFormat[i] (optional) - the list of formats (for comparison).
#                                      Supported values:
#                                      'P' - non-structured
#                                      'X' - simple XML, no headers
#                                      'XX' - XML in MQRFH2.usr (all in one line), XML in body
#                                      'XP' - XML in MQRFH2.usr (all in one line), plain body
#                                      'PX' - plain MQRFH2.usr (all in one line), XML in body
#   
# Environment:
#   MQSIPROFILE (mandatory) - path to MQSI profile (.cmd or .sh)
#   WMQUT_QUEUE_MANAGER (optional) - the queue manager
#   WMQUT_BROKER (optional) - the broker name
#   WMQUT_CONFIG (optional) - the configuration file name, default wmq_ut.conf
#   WMQUT_LOG (optional) - the log file name, default wmq_ut.log
#   WMQUT_ORACLE_DB (optional) - the Oracle connection, user/password@db
#   WMQUT_TEST_TIMEOUT (optional) - the time to wait after sending the message
#   WMQUT_TRACE_LEVEL (optional) - the trace level
#
# Directory structure:
#   ActualResults
#   Data
#   ExpectedResults
#   UserTrace
#
# Dependencies:
#   mqput2, mqcapone should be in PATH
#   sqlplus should be in PATH, if Oracle is used
#   xmllint should be in PATH, if XML messages are processed
#

# set -x

testConfig=${WMQUT_CONFIG:-./wmq_ut.conf}
logFile=${WMQUT_LOG:-./wmq_ut.log}
NO_FORMAT="%02d"

function logMsg
{
  echo "$@" | tee -a $logFile
}

#
# Validate configuration variables
#
function validateConfigFile
{
  if [ -z "$componentName" ] ; then
    logMsg Missing config variable: componentName
    exit 2
  fi
  logMsg Component: $componentName

  queueManager=${queueManager:-$WMQUT_QUEUE_MANAGER}
  if [ -z "$queueManager" ] ; then
    logMsg Missing config variable: queueManager
    logMsg Specify either variable itself in $testConfig
    logMsg or WMQUT_QUEUE_MANAGER environment variable
    exit 2
  fi
  logMsg Queue Manager: $queueManager

  broker=${broker:-$WMQUT_BROKER}
  if [ -z "$broker" ] ; then
    logMsg Missing config variable: broker
    logMsg Specify either variable itself in $testConfig
    logMsg or WMQUT_BROKER environment variable
    exit 2
  fi
  logMsg Broker: $queueManager

  if [ -z "$inputQueue" ] ; then
    logMsg Missing config variable: inputQueue
    exit 2
  fi

  # Consequtive description 1 .. N
  for ((t=1; t <= ${#testDescription[@]} ; t++)) ; do
    if [ -z "${testDescription[$t]}" ] ; then
      logMsg Missing description for the test $t
      exit 2
    fi
  done

  executionGroup=${executionGroup:-default}
  brokerTraceLevel=${brokerTraceLevel:-${WMQUT_TRACE_LEVEL:-normal}}
  logMsg Trace level: $brokerTraceLevel
  testTimeout=${testTimeout:-${WMQUT_TEST_TIMEOUT:-10}}
  logMsg Test timeout: $testTimeout seconds
}

#
# Check filesystem (directories)
#
function checkFilesystem
{
  dirs="ActualResults ExpectedResults Data UserTrace"
  for d in $dirs; do
    if [ ! -d $d ] ; then
      logMsg Missing directory: $d
      exit 3
    fi
  done
}

#
# Check environment variables
#
function checkEnvironment
{
  if [ -z "$MQSIPROFILE" ] ; then
    logMsg The environment variable MQSIPROFILE is not specified
    exit 2
  fi
}

#
# Find the sequence of tests to run
# Parameters: list of tests (can be empty)
#
function findTestsToRun
{
  for ((t=1; t <= ${#testDescription[@]} ; t++)) ; do
    allTests="$allTests $t"
  done
  testsToRun="$*"
  # Nothing specified - run all tests
  if [ -z "$testsToRun" ] ; then
    testsToRun="$allTests"
  fi
  logMsg Tests to run: $testsToRun
}

#
# Retrieve the message from the queue
# Parameters: $1 - the queue name
# Returns: tmp.msg - the message
#
function getWMQMessage
{
  pf=mqcapone.parm
  mf=tmp.msg
  lf=mqcapone.log
  q=$1
  cat > $pf <<EOF
qname=$q
qmgr=$queueManager
striprfh=N
EOF
  mqcapone -f $pf -o $mf >> $lf 2>&1
  nMsgs=`grep "Total messages" $lf | cut -d " " -f 3 | tr -d '\r'`
  cat $lf >> $logFile
  rm -f $lf
  rm -f $pf
  if [ "0" = "$nMsgs" ] ; then
    rm -f $mf
    return 1
  fi
  return 0
}

#
# Run MQSI command
#
function runMqsi
{
  # If that is MS Win - create temporary .cmd file
  if [ -n "$COMSPEC" ] ; then
    cmd=./tmp.cmd
    cat > $cmd << EOF
@echo off
call "$MQSIPROFILE" > nul
$@ >> $logFile
EOF
    ./$cmd
    rm -f $cmd
  else
    . $MQSIPROFILE > /dev/null
    $@
  fi
}

#
# Enable the tracing on the WMQ broker
#
function enableTrace
{
  runMqsi mqsichangetrace $broker -u -e $executionGroup -l $brokerTraceLevel -r
}

#
# Disable the tracing on the WMQ broker
# Save the results to the file
# Parameters: $1 - test number
#
function saveTrace
{
  xml=UserTrace/UT$formattedTestNo.xml
  log=UserTrace/UT$formattedTestNo.log

  runMqsi mqsichangetrace $broker -u -e $executionGroup -l none
  runMqsi mqsireadlog     $broker -u -e $executionGroup -f -o $xml
  runMqsi mqsiformatlog   -i $xml -o $log

  rm -f $xml
}

function runOracle()
{
  stmt="$1"
  file="$2"

  oracleDb=${oracleDb:-$WMQUT_ORACLE_DB}

  if [ -z "$oracleDb" ] ; then
    logMsg Missing config variable: oracleDb
    logMsg Specify either variable itself in $testConfig
    logMsg or WMQUT_ORACLE_DB environment variable
    exit 2
  fi

  if [ -n "$stmt" ] ; then
    echo $stmt | sqlplus -S $oracleDb >> $logFile
  fi

  if [ -n "$file" ] ; then
    cat "$file" | sqlplus -S $oracleDb >> $logFile
  fi
}

#
# Prepare the DB
# Parameters: $1 - test number
#
function setupDb
{
  logMsg "Setting up DB"
  runOracle "${sqlBeforeTest_oracle[$testNo]}" "${sqlFileBeforeTest_oracle[$testNo]}"
}

#
# Cleanup the DB
# Parameters: $1 - test number
#
function cleanupDb
{
  logMsg "Cleaning up DB"
  runOracle "${sqlAfterTest_oracle[$testNo]}" "${sqlFileAfterTest_oracle[$testNo]}"
}

#
# Prepare the test
# Parameters: $1 - test number
#
function setupTest
{
  # Cleanup
  if [ -n "$cleanupQueues" ] ; then
    logMsg -n Cleaning the queues:
    for q in $cleanupQueues; do
      logMsg -n " $q"
      while getWMQMessage $q ; do true; done
    done    
    logMsg
  fi

  setupDb
  enableTrace
}

#
# Execute the test
# Parameters: $1 - test number
#
function executeTest
{
  pf=mqput2.parm

  if [ ! -f Data/TD$formattedTestNo.msg ] ; then
    logMsg Missing test data for the test $t
    exit 2
  fi

  gq=$inputQueue
  tq=${testInputQueue[$testNo]}
  tq=${tq:-$gq}

cat > $pf << EOF
[header]
qname=$tq
qmgr=$queueManager
msgcount=1
rfh=A
[filelist]
Data/TD$formattedTestNo.msg
EOF
  logMsg Sending message to $tq ...
  mqput2 -f $pf >> $logFile
  rm -f $pf

  logMsg Waiting ...
  sleep $testTimeout
}

#
# Process XML file
# Drop all lines related to $ignoreXmlElements
# Parameters: $1 - the xml file name
#
function processXml
{
  xml=$1
  processedXml=$xml.xml
  xmllint --format $xml > $processedXml
  for e in $ignoreXmlElements ; do
    mv $processedXml $xml
    grep -v "<$e>" $xml > $processedXml
  done
}

#
# Extract USR folder ($ar and $er)
# Assumption: the entire usr folder is within 1st line of the message
#
function extractUSR
{
  head -1 $ar | awk '{ split($0, a, "<\\/?usr>"); print a[2]; }' > $ar.usr
  head -1 $er | awk '{ split($0, a, "<\\/?usr>"); print a[2]; }' > $er.usr
}

#
# Compare USR folders ($ar and $er)
# Assumption: the entire usr folder is within 1st line of the message
#
function compareUSRAsPlain
{
  # Check XML in usr folder (RFH2) - assuming it is all in 1st line
  extractUSR
  diff -u $er.usr $ar.usr | tee -a $logFile
}

#
# Compare USR folders ($ar and $er)
# Assumption: the entire usr folder is within 1st line of the message
#
function compareUSRAsXML
{
  # Check XML in usr folder (RFH2) - assuming it is all in 1st line
  extractUSR
  processXml $ar.usr
  processXml $er.usr
  diff -u $er.usr.xml $ar.usr.xml | tee -a $logFile
}

#
# Extract data after USR folder ($ar and $er)
# Assumption: the entire usr folder is within 1st line of the message
#
function extractDataAfterUSR
{
    head -1 $ar | awk '{ split($0, a, "<\\/usr>[[:blank:]]*"); print a[2]; }' > $ar.data
    head -1 $er | awk '{ split($0, a, "<\\/usr>[[:blank:]]*"); print a[2]; }' > $er.data
    tail --lines=+2 $ar >> $ar.data
    tail --lines=+2 $er >> $er.data
}

#
# Compare Data XML ($ar and $er)
#
function compareDataAsXML
{
    extractDataAfterUSR
    processXml $ar.data
    processXml $er.data
    diff -u $er.data.xml $ar.data.xml | tee -a $logFile
}
#
# Compare the actual results with expected
# Parameters: $1 - result number
#
function compareResults
{
  ar=ActualResults/AR$formattedResultNo.msg
  er=ExpectedResults/ER$formattedResultNo.msg
  outputFormat=`echo ${testOutputFormat[$testNo]} | cut -d " " -f $localResultNo`

  if [ "X" = "$outputFormat" ] ; then
    processXml $ar
    processXml $er
    diff -u $er.xml $ar.xml | tee -a $logFile
  elif [ "XX" = "$outputFormat" ] ; then
    compareUSRAsXML
    compareDataAsXML
  elif [ "XP" = "$outputFormat" ] ; then
    compareUSRAsXML
    extractDataAfterUSR
    diff -u $er.data $ar.data | tee -a $logFile
  elif [ "PX" = "$outputFormat" ] ; then
    compareUSRAsPlain
    compareDataAsXML
  else
    diff -a -u $er $ar | tee -a $logFile
  fi
}

#
# Reset the result counter
#
function resetResultNo
{
  resultNo=1
  formattedResultNo=01
}

#
# Increment global result number
#
function incResultNo
{
  resultNo=$(( $resultNo + 1 ))
  formattedResultNo=`printf $NO_FORMAT $resultNo`
}

#
# Retrieve the results and check them
# Parameters: $1 - test number
#
function analizeTest
{
  saveTrace

  localResultNo=1
  for q in ${testOutputQueues[$testNo]} ; do
    logMsg Checking output queue $q
    if ! getWMQMessage $q ; then
      logMsg Expected a message from $q, no message available
    else
      mv tmp.msg ActualResults/AR$formattedResultNo.msg
      compareResults $formattedResultNo
    fi
    incResultNo
    localResultNo=$(( $localResultNo + 1 ))
  done

  for q in ${testEmptyQueues[$testNo]} ; do
    logMsg Checking queue $q to be empty
    if getWMQMessage $q ; then
      logMsg Expected queue $q to be empty - but at least one message is available
      mv tmp.msg $q.msg
    fi
  done
}

#
# Retrieve the results and check them
# Parameters: $1 - test number
#
function cleanupTest
{
  cleanupDb
}

#
# Main loop over tests
#
function mainLoop
{
  resetResultNo

  for testNo in $allTests; do
    # Check if the current test has to be run
    doRun=0
    for t in $testsToRun; do
      if [ "$t" = "$testNo" ] ; then
        doRun=1
        break
      fi
    done

    # If the test is to be run - do it, 
    # otherwise just increase result counter
    if [ 1 = $doRun ] ; then
      logMsg ----- Test $testNo: ${testDescription[$testNo]} -----
      formattedTestNo="`printf $NO_FORMAT $testNo`"
      setupTest
      executeTest
      analizeTest
      cleanupTest
    else
      for q in ${testOutputQueues[$testNo]} ; do
        incResultNo
      done
    fi
  done
}

#
# Global entry point
#

if [ -f $testConfig ] ; then
  . $testConfig
else
  echo The test config file $testConfig does not exists
  exit 1
fi

echo > $logFile

logMsg Running tests at `date`

validateConfigFile

checkEnvironment

checkFilesystem

logMsg Component: $componentName

findTestsToRun $*

mainLoop

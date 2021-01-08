#!/usr/bin/perl
# Attention Circuits Control Laboratory - NeurAVR helper scripts
# Arduino communications library.
# This program talks to an Arduino (or compatible serial device), handling
# connection and low-level communication.
# Written by Christopher Thomas.
# Copyright (c) 2020 by Vanderbilt University. This work is licensed under
# the Creative Commons Attribution-ShareAlike 4.0 International License.


#
# Includes
#

use strict;
use warnings;

use Time::HiRes;
use IPC::Open2;



#
# Global Variables
#


# Throttle interval for serial writes.
# If zero, no throttling is performed.
my ($ACLI_throttle_micros);
$ACLI_throttle_micros = 0;


# Timeout for pattern-waiting, in seconds.
# If zero, this will wait forever.
my ($ACLI_wait_timeout_secs, $ACLI_wait_timeout_message);
$ACLI_wait_timeout_secs = 0;
# If defined, this string will be send to STDOUT when a timeout occurs.
$ACLI_wait_timeout_message = undef;


# Implementation switches.
my ($ACLI_io_uses_syscalls, $ACLI_relay_uses_syscalls);
$ACLI_io_uses_syscalls = 1;
$ACLI_relay_uses_syscalls = 1;


# Tattle switches.
my ($ACLI_tattle, $ACLI_tattle_verbose);
my ($ACLI_tattle_ridiculous, $ACLI_tattle_fhcanread);
my ($ACLI_tattle_from_ard);
my ($ACLI_tattle_until_pattern);
$ACLI_tattle = 0;
$ACLI_tattle_verbose = 0;
$ACLI_tattle_ridiculous = 0;
$ACLI_tattle_fhcanread = 0;
$ACLI_tattle_from_ard = 0;
$ACLI_tattle_until_pattern = 0;



#
# Public Functions
#

# Forces a yield.
# FIXME - This deliberately has nonzero delay!
# We're getting CPU hogging with zero delay.
# No arguments.
# No return value.

sub ACLI_Yield
{
  # System timeslice granularity seems to be about 0.1 ms, with explicit
  # timeslice clocking at about 1 ms if I understand correctly.
  # So, this could take about 1 ms worst-case.

  # FIXME - Values are black magic.
  # 0.1 ms is a practical minimum, and there's no advantage past 1 ms.
  Time::HiRes::usleep(300);
}



# This returns both ends of an anonymous pipe for inter-process
# communication. Auto-flush is enabled for both ends.
# FIXME - This still seems to use line-based buffering.
# No arguments.
# Returns (reader, writer).

sub ACLI_GetNewPipe
{
  my ($reader, $writer);
  local (*TEMPREAD, *TEMPWRITE);

  # Diagnostics.
  if ($ACLI_tattle)
  { print STDERR "-- ACLI_GetNewPipe called.\n"; }

  # FIXME - No error checking.
  pipe(TEMPREAD, TEMPWRITE);

  # Make both of these auto-flush.
  # Do this the longer but slightly less cryptic way.
  {
    my ($oldhandle);

    # This saves the old default handle, selects the desired pipe as default,
    # sets that to autoflush, and then sets the old handle as default again.

    $oldhandle = select(TEMPWRITE);
    $| = 1;
    select(TEMPREAD);
    $| = 1;
    select($oldhandle);
  }

  # Put these in scalars, and return them.

  $reader = *TEMPREAD;
  $writer = *TEMPWRITE;

  # Diagnostics.
  if ($ACLI_tattle_verbose)
  { print STDERR "-- ACLI_GetNewPipe finished.\n"; }

  return ($reader, $writer);
}



# Does a non-blocking check to see if a filehandle can be read from.
# Arg 0 is the file handle to test.
# Returns 1 if the file handle can be read from now and 0 otherwise.

sub ACLI_FilehandleCanRead
{
  my ($filehandle, $can_read);
  my ($filevec, $filecount);

  $filehandle = $_[0];
  $can_read = 0;

  if (!(defined $filehandle))
  {
    print "### [ACLI_FilehandleCanRead]  Bad arguments.\n";
    # Don't firehose.
    sleep(1);
  }
  else
  {
    # Diagnostics.
    if ($ACLI_tattle_fhcanread)
    { print STDERR "-- ACLI_FileHandleCanRead called.\n"; }

    # Build a vector containing only this filehandle.
    $filevec = '';
    vec($filevec, fileno($filehandle), 1) = 1;

    # Use a timeout of zero, to poll.
    # This overwrites the vector, but we don't care about that.
    $filecount = select($filevec, undef, undef, 0);

    if (0 < $filecount)
    { $can_read = 1; }
  }

  return $can_read;
}



# Reads all pending data from a filehandle using sysread().
# This is either raw or line-based. Raw is non-blocking, while line-based
# spins until it sees \r or \n.
# Arg 0 is the filehandle to read.
# Arg 1 is 0 for raw and 1 for line-based.
# Returns a string containing all bytes read (possibly an empty string).

sub ACLI_SysReadFromFilehandle
{
  my ($filehandle, $want_lines, $result);
  my ($count, $thisline, $done);

  $filehandle = $_[0];
  $want_lines = $_[1];

  $result = '';

  if (!( (defined $filehandle) && (defined $want_lines) ))
  {
    print "### [ACLI_SysReadFromFilehandle]  Bad arguments.\n";
  }
  else
  {
    $done = 0;

    while (!$done)
    {
      if (ACLI_FilehandleCanRead($filehandle))
      {
        $thisline = '';
        # Read one byte at a time. Possibly not a great idea.
        $count = sysread($filehandle, $thisline, 1);

        if ( (defined $count) && ($count > 0) )
        {
          # We read a character successfully.
          $result .= $thisline;

          # Check for end-of-line.
          if ( $want_lines && ($thisline =~ m/[\r\n]/) )
          { $done = 1; }
        }
        elsif (!$want_lines)
        {
          # Stop spinning if we couldn't read and aren't waiting for a line.
          $done = 1;
        }
      }
      elsif (!$want_lines)
      {
        # Stop spinning if we couldn't read and aren't waiting for a line.
        $done = 1;
      }
    }
  }

  return $result;
}



# Initializes a communicatons handle hash and starts up a buffering thread.
# Arg 0 is the "read" filehandle for the conenction we're wrapping.
# Arg 1 is the "write" filehandle for the connection we're wrapping.
# Arg 2 points to a list of PIDs associated with this connection.
# Returns a communications handle (hash pointer).

sub ACLI_SetUpCommHandle
{
  my ($reader, $writer, $pidlist_p, $handle_p);
  my ($childpid);
  my ($relayread, $relaywrite);
  my ($queryread, $querywrite, $responseread, $responsewrite);


  $reader = $_[0];
  $writer = $_[1];
  $pidlist_p = $_[2];

  $handle_p = undef;


  if (!( (defined $reader) && (defined $writer) && (defined $pidlist_p) ))
  {
    print "### [ACLI_SetUpCommHandle]  Bad arguments.\n";
  }
  else
  {
    # Diagnostics.
    if ($ACLI_tattle)
    { print STDERR "-- ACLI_SetUpCommHandle called.\n"; }

    # Initialize.
    $handle_p =
    {
      'rawreader' => $reader,
      'rawwriter' => $writer,
      'pidlist' => $pidlist_p,
      'nonblocking' => 1
    };


    # Set the handles to auto-flush.
    # Do this the longer but slightly less cryptic way.
    {
      my ($oldhandle);

      $oldhandle = select($reader);
      $| = 1;
      select($writer);
      $| = 1;
      select($oldhandle);
    }


    # Trap broken-pipe signals.
    $SIG{PIPE} = sub {};


    # Add pipes.
    # These _do_ work properly with "FilehandleCanRead".
    ($relayread, $relaywrite) = ACLI_GetNewPipe();
    ($queryread, $querywrite) = ACLI_GetNewPipe();
    ($responseread, $responsewrite) = ACLI_GetNewPipe();

    # Make note of these in the handle.
    $$handle_p{'relayreader'} = $relayread;
    $$handle_p{'relaywriter'} = $relaywrite;
    $$handle_p{'queryreader'} = $queryread;
    $$handle_p{'querywriter'} = $querywrite;
    $$handle_p{'responsereader'} = $responseread;
    $$handle_p{'responsewriter'} = $responsewrite;


    # Spawn a child process for handling requests.

    $childpid = fork();
    if (0 == $childpid)
    {
      # We're the child. Spin forever, handling requests.

      my (@buffer, $thisline);
      @buffer = ();

      # Diagnostics.
      if ($ACLI_tattle)
      { print STDERR "-- ACLI_SetUpCommHandle query thread started.\n"; }

      while (1)
      {
        if (ACLI_FilehandleCanRead($queryread))
        {
          # A command from the client.

          # Diagnostics.
          if ($ACLI_tattle_ridiculous)
          { print STDERR "-- ACLI_SetupCommHandle query got a command:\n"; }

          if ($ACLI_relay_uses_syscalls)
          { $thisline = ACLI_SysReadFromFilehandle($queryread, 1); }
          else
          { $thisline = <$queryread>; }

          # Diagnostics.
          if ($ACLI_tattle_ridiculous)
          {
            my ($scratch);
            $scratch = $thisline;
            chomp($scratch);
            print STDERR $scratch . "\n";
          }

          # Only handle this if it's a command we recognize.
          # Otherwise silently do nothing.

          if ($thisline =~ m/do you have lines/i)
          {
            if (defined $buffer[0])
            {
              # Diagnostics.
              if ($ACLI_tattle_verbose)
              { print STDERR "-- ACLI_SetupCommHandle query has lines.\n"; }

              if ($ACLI_relay_uses_syscalls)
              { syswrite($responsewrite, "yes\n"); }
              else
              { print $responsewrite "yes\n"; }
            }
            else
            {
              # Diagnostics.
              if ($ACLI_tattle_verbose)
              { print STDERR "-- ACLI_SetUpCommHandle query no lines.\n"; }

              if ($ACLI_relay_uses_syscalls)
              { syswrite($responsewrite, "no\n"); }
              else
              { print $responsewrite "no\n"; }
            }
          }
          elsif ($thisline =~ m/send a line/i)
          {
            # FIXME - Send an empty line if we're asked for a line and don't
            # have one. This shouldn't happen, but if it does happen, we don't
            # want the client to hang.
            if (defined $buffer[0])
            {
              $thisline = shift @buffer;

              # Diagnostics.
              if ($ACLI_tattle_verbose)
              {
                print STDERR "-- ACLI_SetupCommHandle query data reply:\n";
                print STDERR $thisline;
              }


              if ($ACLI_relay_uses_syscalls)
              { syswrite($responsewrite, $thisline); }
              else
              { print $responsewrite $thisline; }
            }
            else
            {
              # Diagnostics.
              if ($ACLI_tattle_verbose)
              { print STDERR "-- ACLI_SetUpCommHandle query empty reply.\n"; }

              if ($ACLI_relay_uses_syscalls)
              { syswrite($responsewrite, "\n"); }
              else
              { print $responsewrite "\n"; }
            }
          }
          else
          {
            my ($scratch);

            $scratch = $thisline;
            chomp($scratch);

            print "### [ACLI_SetUpCommHandle query thread]"
              . "  Unrecognized command: \"$scratch\"\n";
          }
        }

        if (ACLI_FilehandleCanRead($relayread))
        {
          # Data from the Arduino.

          # Diagnostics.
          if ($ACLI_tattle_verbose)
          { print STDERR "-- ACLI_SetUpCommHandle query got data:\n"; }

          if ($ACLI_relay_uses_syscalls)
          { $thisline = ACLI_SysReadFromFilehandle($relayread, 1); }
          else
          { $thisline = <$relayread>; }

          # Diagnostics.
          if ($ACLI_tattle_verbose)
          { print STDERR $thisline; }

          push @buffer, $thisline;
        }

        # Don't peg the CPU.
        ACLI_Yield();
      }
    }
    else
    {
      # We're the parent. Record the child PID.
      push @$pidlist_p, $childpid;
    }


    # Spawn a child process for relaying data from the arduino to the buffer.

    $childpid = fork();
    if (0 == $childpid)
    {
      # We're the child. Spin forever, relaying to the buffer thread.
      # These operations are blocking, but the buffer thread should always
      # respond quickly.

      my ($thisline);

      # Diagnostics.
      if ($ACLI_tattle)
      { print STDERR "-- ACLI_SetUpCommHandle buffer thread started.\n"; }

      while (1)
      {
        if ($ACLI_io_uses_syscalls)
        { $thisline = ACLI_SysReadFromFilehandle($reader, 1); }
        else
        { $thisline = <$reader>; }

        # If we had a connection error, this may be undef.
        if (defined $thisline)
        {
          # Diagnostics.
          if ($ACLI_tattle_verbose || $ACLI_tattle_from_ard)
          {
            print STDERR "-- ACLI_SetUpCommHandle buffer thread got data:\n";
            print STDERR $thisline;
          }

          if ($ACLI_relay_uses_syscalls)
          { syswrite($relaywrite, $thisline); }
          else
          { print $relaywrite $thisline; }
        }
        else
        {
          # Something is very wrong.
          print "### [ACLI_SetUpCommHandle buffer thread]  Can't read!\n";
          # FIXME - Throttle disaster reporting.
          sleep(1);
        }

        # Don't peg the CPU.
        ACLI_Yield();
      }
    }
    else
    {
      # We're the parent. Record the child PID.
      push @$pidlist_p, $childpid;
    }

    # Diagnostics.
    if ($ACLI_tattle)
    { print STDERR "-- ACLI_SetUpCommHandle finished.\n"; }
  }


  # Done.
  return $handle_p;
}



# Does a non-blocking check to see if a handle hash can be read from.
# This queries the buffer thread to ask if there's pending data.
# Arg 0 is the handle to test.
# Returns 1 if the handle can be read from now and 0 otherwise.

sub ACLI_HandleCanRead
{
  my ($handle, $can_read);
  my ($reader, $writer);
  my ($response);

  $handle = $_[0];
  $can_read = 0;

  if (!(defined $handle))
  {
    print "### [ACLI_HandleCanRead]  Bad arguments.\n";
    # Don't firehose.
    sleep(1);
  }
  else
  {
    # Diagnostics.
    if ($ACLI_tattle_ridiculous)
    { print STDERR "-- ACLI_HandleCanRead called.\n"; }

    $reader = $$handle{'responsereader'};
    $writer = $$handle{'querywriter'};

    # This handshake is blocking, but should always respond immediately.
    if ($ACLI_relay_uses_syscalls)
    {
      syswrite($writer, "do you have lines?\n");
      $response = ACLI_SysReadFromFilehandle($reader, 1);
    }
    else
    {
      print $writer "do you have lines?\n";
      $response = <$reader>;
    }

    if ($response =~ m/yes/)
    { $can_read = 1; }

    # Diagnostics.
    if ($ACLI_tattle_ridiculous)
    {
      my ($scratch);
      $scratch = $response;
      chomp($scratch);
      print STDERR
        "-- ACLI_HandleCanRead returns $can_read (from \"$scratch\").\n";
    }
  }

  return $can_read;
}



# Does a non-blocking read from the specified handle.
# Arg 0 is the handle to test.
# Returns the line read, if present, or undef if no line was available.

sub ACLI_HandleTryRead
{
  my ($handle, $result);
  my ($reader, $writer);

  $handle = $_[0];

  $result = undef;

  # Diagnostics.
  if ($ACLI_tattle_ridiculous)
  { print STDERR "-- ACLI_HandleTryRead called.\n"; }

  if (!(defined $handle))
  {
    print "### [ACLI_HandleTryRead]  Bad arguments.\n";
    # Don't firehose.
    sleep(1);
  }
  elsif (ACLI_HandleCanRead($handle))
  {
    $reader = $$handle{'responsereader'};
    $writer = $$handle{'querywriter'};

    # Diagnostics.
    if ($ACLI_tattle_verbose)
    { print STDERR "-- ACLI_HandleTryRead got line:\n"; }

    # This handshake is blocking, but should always respond immediately.
    if ($ACLI_relay_uses_syscalls)
    {
      syswrite($writer, "send a line\n");
      $result = ACLI_SysReadFromFilehandle($reader, 1);
    }
    else
    {
      print $writer "send a line\n";
      $result = <$reader>;
    }

    # Diagnostics.
    if ($ACLI_tattle_verbose)
    { print STDERR $result; }
  }

  return $result;
}



# Polls the serial port, returning all already-buffered data.
# Arg 0 is the device handle to read from.
# Returns previously-buffered text (possibly an empty string).

sub ACLI_ReadPendingText
{
  my ($handle, $result);
  my ($thisline);

  $handle = $_[0];
  $result = '';

  if (!(defined $handle))
  {
    print "### [ACLI_ReadPendingText]  Bad arguments.\n";
  }
  else
  {
    # Diagnostics.
    if ($ACLI_tattle)
    { print STDERR "-- ACLI_ReadPendingText called.\n"; }

    while ( defined ($thisline = ACLI_HandleTryRead($handle)) )
    { $result .= $thisline; }

    # Diagnostics.
    if ($ACLI_tattle)
    { print STDERR "-- ACLI_ReadPendingText finished.\n"; }
  }

  return $result;
}



# Polls the serial port, reading data until the specified time().
# This works with or without traffic.
# Arg 0 is the device handle to read from.
# Arg 1 is the timestamp to terminate at.
# Returns a string containing the characters read.

sub ACLI_ReadSerialUntilTime
{
  my ($handle, $endtime, $result);
  my ($thisline);

  $handle = $_[0];
  $endtime = $_[1];

  $result = '';

  if (!( (defined $handle) && (defined $endtime) ))
  {
    print "### [ACLI_ReadSerialUntilTime]  Bad arguments.\n";
  }
  else
  {
    # Diagnostics.
    if ($ACLI_tattle)
    { print STDERR "-- ACLI_ReadSerialUntilTime called.\n"; }

    while (time() < $endtime)
    {
      $thisline = ACLI_HandleTryRead($handle);

      if (defined $thisline)
      {
        $result .= $thisline;
      }
      else
      {
        # Avoid pegging the CPU while spinning.
        ACLI_Yield();
      }
    }

    # Diagnostics.
    if ($ACLI_tattle)
    { print STDERR "-- ACLI_ReadSerialUntilTime finished.\n"; }
  }

  return $result;
}



# Sets the default timeout for "ReadSerialUntilFoo()".
# Set this to zero to wait forever (or until an explicitly specified time).
# If a timeout occurs, a message is displayed to STDOUT (if defined).
# Set the message to undef to suppress reporting.
# Arg 0 is the desired timeout in seconds.
# Arg 1 (optional) is a message to display when a timeout occurs.
# No return value.

sub ACLI_SetTimeout
{
  my ($newtimeout, $newmessage);

  $newtimeout = $_[0];
  $newmessage = $_[1];  # May be undefined.

  if (!(defined $newtimeout))
  {
    print "### [ACLI_SetTimeout]  Bad arguments.\n";
  }
  else
  {
    $newtimeout = int($newtimeout);

    if (1 > $newtimeout)
    { $ACLI_wait_timeout_secs = 0; }
    else
    { $ACLI_wait_timeout_secs = $newtimeout; }

    $ACLI_wait_timeout_message = $newmessage;

    # Diagnostics.
    if ($ACLI_tattle)
    {
      print STDERR
"-- ACLI_SetTimeout called; set to $ACLI_wait_timeout_secs seconds.\n";

      if (defined $ACLI_wait_timeout_message)
      {
        my ($scratch);
        $scratch = $ACLI_wait_timeout_message;
        chomp($scratch);
        print STDERR "-- Message: \"$scratch\"\n";
      }
      else
      { print STDERR "-- No timeout message.\n"; }
    }
  }
}



# Queries the default timeout for "ReadSerialUntilFoo()".
# No arguments.
# Returns the default timeout in seconds (0 for "wait forever").

sub ACLI_QueryTimeout
{
  # Diagnostics.
  if ($ACLI_tattle)
  {
    print STDERR
      "-- ACLI_QueryTimeout returns $ACLI_wait_timeout_secs seconds.\n";
  }

  return $ACLI_wait_timeout_secs;
}



# Queries the default timeout reporting message for "ReadSerialUntilFoo()".
# No arguments.
# Returns the message if set, and "undef" if no message is set.

sub ACLI_QueryTimeoutMessage
{
  # Diagnostics.
  if ($ACLI_tattle)
  {
    if (defined $ACLI_wait_timeout_message)
    {
      my ($scratch);
      $scratch = $ACLI_wait_timeout_message;
      chomp($scratch);
      print STDERR "-- ACLI_QueryTimeoutMessage returns: \"$scratch\"\n";
    }
    else
    { print STDERR "-- ACLI_QueryTimeoutMessage: No timeout message.\n"; }
  }

  return $ACLI_wait_timeout_message;
}



# Polls the serial port, reading data until the specified text occurs.
# This looks for m/$pattern/msi (case insensitive and spanning lines).
# NOTE - Without an end time, this will happily wait forever.
# A global default timeout can also be set.
# Arg 0 is the device handle to read from.
# Arg 1 is the regex to terminate at.
# Arg 2 (optional) is a timestamp to terminate at.
# Returns a string containing the characters read.

sub ACLI_ReadSerialUntilPattern
{
  my ($handle, $pattern, $endtime, $result);
  my ($thisline, $done);

  $handle = $_[0];
  $pattern = $_[1];
  $endtime = $_[2];  # May be undefined.

  $result = '';

  if (!( (defined $handle) && (defined $pattern) ))
  {
    print "### [ACLI_ReadSerialUntilPattern]  Bad arguments.\n";
  }
  else
  {
    # If we don't have a defined end time, set a default.
    if ( (!(defined $endtime)) && (0 < $ACLI_wait_timeout_secs) )
    {
      $endtime = time() + $ACLI_wait_timeout_secs;
    }

    # Diagnostics.
    if ($ACLI_tattle || $ACLI_tattle_until_pattern)
    {
      print STDERR "-- ACLI_ReadSerialUntilPattern called.\n";
      if (defined $endtime)
      { print STDERR "-- Looking for \"$pattern\" before time $endtime.\n"; }
      else
      { print STDERR "-- Looking for \"$pattern\" (waiting forever).\n"; }
    }

    # Spin until an ending condition is met.
    $done = 0;
    while (!$done)
    {
      if ($result =~ m/$pattern/msi)
      {
        $done = 1;

        if ($ACLI_tattle_until_pattern)
        { print STDERR "-- Matched \"$pattern\".\n"; }
      }

      if (defined $endtime)
      {
        if (time() >= $endtime)
        {
          $done = 1;

          # Send a timeout report to STDOUT if requested.
          if (defined $ACLI_wait_timeout_message)
          { print $ACLI_wait_timeout_message; }

          if ($ACLI_tattle_until_pattern)
          { print STDERR "-- Timed out without matching.\n"; }
        }
      }

      if (!$done)
      {
        $thisline = ACLI_HandleTryRead($handle);

        if (defined $thisline)
        {
          $result .= $thisline;
        }
        else
        {
          # Avoid pegging the CPU while spinning.
          ACLI_Yield();
        }
      }
    }

    # Diagnostics.
    if ($ACLI_tattle || $ACLI_tattle_until_pattern)
    { print STDERR "-- ACLI_ReadSerialUntilPattern finished.\n"; }
  }

  return $result;
}



# Sets the per-character throttling delay.
# Set this to zero to disable throttling.
# Arg 0 is the desired delay in milliseconds.
# No return value.

sub ACLI_SetThrottle
{
  my ($newthrottle);

  $newthrottle = $_[0];

  if (!(defined $newthrottle))
  {
    print "### [ACLI_SetThrottle]  Bad arguments.\n";
  }
  else
  {
    if (1 > $newthrottle)
    { $ACLI_throttle_micros = 0; }
    else
    { $ACLI_throttle_micros = int((1000 * $newthrottle) + 0.49); }

    # Diagnostics.
    if ($ACLI_tattle)
    {
      print STDERR
        "-- ACLI_SetThrottle called ($ACLI_throttle_micros microseconds).\n";
    }
  }
}



# Queries the per-character throttling delay.
# No arguments.
# Returns the throttling delay in milliseconds (0 for no throttling).

sub ACLI_QueryThrottle
{
  # Diagnostics.
  if ($ACLI_tattle)
  {
    print STDERR
      "-- ACLI_QueryThrottle called ($ACLI_throttle_micros microseconds).\n";
  }

  return int(($ACLI_throttle_micros + 500) / 1000);
}



# Writes a string to a serial port.
# If the throttle delay is nonzero, a delay occurs before each character is
# written.
# Arg 0 is the device handle to write to.
# Arg 1 is the string to write.
# No return value.

sub ACLI_WriteSerial
{
  my ($handle, $message);
  my ($writer);
  my (@charlist, $thischar);

  $handle = $_[0];
  $message = $_[1];

  if (!( (defined $handle) && (defined $message) ))
  {
    print "### [ACLI_WriteSerial]  Bad arguments.\n";
  }
  else
  {
    # Diagnostics.
    if ($ACLI_tattle)
    {
      my ($scratch);
      $scratch = $message;
      chomp($scratch);
      print STDERR "-- ACLI_WriteSerial called. Data:\n";
      print STDERR $scratch . "\n";
    }

    $writer = $$handle{rawwriter};

    if (0 < $ACLI_throttle_micros)
    {
      @charlist = split(//,$message);
      foreach $thischar (@charlist)
      {
        Time::HiRes::usleep($ACLI_throttle_micros);

        if ($ACLI_io_uses_syscalls)
        { syswrite($writer, $thischar); }
        else
        { print $writer $thischar; }
      }
    }
    else
    {
      if ($ACLI_io_uses_syscalls)
      { syswrite($writer, $message); }
      else
      { print $writer $message; }
    }

    # Diagnostics.
    if ($ACLI_tattle)
    { print STDERR "-- ACLI_WriteSerial finished.\n"; }
  }
}



# Returns the current time in microseconds.
# FIXME - This requires 64-bit integers.
# No arguments.
# Returns an integer timestamp.

sub ACLI_GetTimeMicros
{
  my ($seconds, $micros, $result);

  ($seconds, $micros) = Time::HiRes::gettimeofday();

  # These are probably already integers, but bulletproof this anyways.
  $result = (1000000 * int($seconds)) + int($micros);

  return $result;
}



# This attempts to autodetect a serial device.
# No arguments.
# Returns the device name if successful or undef if not.

sub ACLI_AutoDetectSerialDevice
{
  my ($devchosen);
  my ($cmd, @result);
  my ($thisline, @candidates);

  $devchosen = undef;

  $cmd = 'ls /dev/tty*';
  @result = `$cmd`;

  @candidates = ();
  foreach $thisline (@result)
  {
    chomp($thisline);

    if ( ($thisline =~ m/ttyACM\d+/i)
      || ($thisline =~ m/tty.*usbmodem/i) )
    {
      push @candidates, $thisline;
    }
  }

  @candidates = sort @candidates;

  if (defined $candidates[0])
  { $devchosen = $candidates[0]; }

  # Diagnostics.
  if ($ACLI_tattle)
  {
    if (defined $devchosen)
    { print STDERR "-- ACLI_AutoDetectSerialDevice found: $devchosen\n"; }
    else
    { print STDERR "-- ACLI_AutoDetectSerialDevice couldn't find device.\n"; }
  }

  return $devchosen;
}



# Sends probe commands to the Arduino for the specified duration.
# Among other things this can be used to generate traffic to avoid
# deadlocking during initial handshaking.
# This returns immediately, with a child process doing the sending.
# NOTE - Command transmission is not MT-safe! Make sure nothing else is
# writing at the same time this is.
# Arg 0 is the serial handle to use.
# Arg 1 is the string to send to the arduino (including CRLF if needed).
# Arg 2 is the transmission interval in seconds.
# Arg 3 is the time() at which to terminate, or 0 to loop forever.
# Returns the PID of the child process.

sub ACLI_SendProbeCommands
{
  my ($handle, $cmdstring, $cmdinterval, $endtime, $childpid);

  $handle = $_[0];
  $cmdstring = $_[1];
  $cmdinterval = $_[2];
  $endtime = $_[3];

  $childpid = undef;


  if (!( (defined $handle) && (defined $cmdstring)
    && (defined $cmdinterval) && (defined $endtime) ))
  {
    print "### [ACLI_SendProbeCommands]  Bad arguments.\n";
  }
  else
  {
    # Force sanity.
    $cmdinterval = int($cmdinterval);
    $endtime = int($endtime);

    if (1 > $cmdinterval)
    { $cmdinterval = 1; }

    # Diagnostics.
    if ($ACLI_tattle)
    {
      my ($scratch);
      $scratch = $cmdstring;
      chomp($scratch);
      print STDERR
        "-- ACLI_SendProbeCommands called. $cmdinterval seconds, data:\n";
      print STDERR $scratch . "\n";
    }

    # Spawn a child process.
    $childpid = fork();
    if (0 == $childpid)
    {
      # We're the child.

      # Send commands, looping until we're done.
      while (time() < $endtime)
      {
        sleep($cmdinterval);
        ACLI_WriteSerial($handle, $cmdstring);
      }

      # Diagnostics.
      if ($ACLI_tattle)
      { print STDERR "-- ACLI_SendProbeCommands child finished.\n"; }

      # Die gracefully.
      exit(0);
    }

    # The parent returns immediately.

    # Diagnostics.
    if ($ACLI_tattle)
    { print STDERR "-- ACLI_SendProbeCommands parent finished.\n"; }
  }

  return $childpid;
}



# This initiates a serial link with an Arduino.
# This shouldn't _need_ traffic from the arduino, but it might still help.
# An optional keepalive command can be repeatedly sent to generate this.
# NOTE - This can also connect to executable emulated Arduino devices. If
# the baud rate is the string 'emulated', the "serial device" is assumed to
# be an executable filename and is run.
# Arg 0 is the serial device to use for the connection.
# Arg 1 is the baud rate to use.
# Arg 2 (optional) is a keepalive command to repeatedly send.
# Returns a communications handle (hash pointer).

sub ACLI_ConnectToArduino
{
  my ($device, $baud, $keepalive, $handle);
  local (*READHANDLE, *WRITEHANDLE);
  my ($reader, $writer);
  my ($childpid, $keepalivepid);
  my ($endtime);

  $device = $_[0];
  $baud = $_[1];
  $keepalive = $_[2]; # May be undefined.

  $handle = undef;


  if (!( (defined $device) && (defined $baud) ))
  {
    print "### [ACLI_ConnectToArduino]  Bad arguments.\n";
  }
  else
  {
    # Diagnostics.
    if ($ACLI_tattle)
    { print STDERR "-- ACLI_ConnectToArduino called.\n"; }

    # Banner.
# FIXME - Don't emit text unless there's an error.
#    print "-- Connecting on serial port \"$device\" and $baud baud.\n";

    if ('emulated' eq $baud)
    {
      # This is an executable file. Run it directly.

      # Much as with exec(), we need to pass a list if we want the real pid.
      # A single string gets passed to a shell instance for interpretation.
      $childpid = open2(*READHANDLE, *WRITEHANDLE, $device);
    }
    else
    {
      # This is a serial port. Wrap "cu" to talk to it.

      # Much as with exec(), we need to pass a list if we want the real pid.
      # A single string gets passed to a shell instance for interpretation.
      $childpid = open2(*READHANDLE, *WRITEHANDLE,
        'cu', '-l', $device, '-s', $baud);
    }


    if (!(defined $childpid))
    {
      print "### [ConnectToArduino]  Couldn't create serial port handle.\n";
    }
    else
    {
      # Build the handle hash, and set up buffer threads.
      $reader = *READHANDLE;
      $writer = *WRITEHANDLE;
      $handle = ACLI_SetUpCommHandle($reader, $writer, [ $childpid ]);


      # The first second or so of the connection is glitchy.

      # FIXME - Connecting at 230k using a FTDI dongle gives endless
      # corruption, but it works when done by _hand_. No idea why.
      # By hand, hit enter once, read garbage, and everything else is fine.
# FIXME - Might have fixed this; test it.

      # First, wait for a couple of seconds.
      sleep(2);

      # FIXME - Send an empty line, to address the above issue.
      ACLI_WriteSerial($handle, "\n");

      # Decide how long our glitch period will last.
      $endtime = time() + 2;

      # Next, set up the keepalive if we need one.
      # This should run _longer_ than our "read until" loop will.
      $keepalivepid = undef;
      if (defined $keepalive)
      {
        $keepalivepid =
          ACLI_SendProbeCommands($handle, $keepalive, 1, $endtime + 2);
      }

      # Read and ignore everything for 1-2 seconds.
      ACLI_ReadSerialUntilTime($handle, $endtime);

      # Wait for the keepalive process to finish.
      if (defined $keepalivepid)
      {
        waitpid($keepalivepid, 0);
      }

      # The connection should now be stable.
    }

    # Diagnostics.
    if ($ACLI_tattle)
    { print STDERR "-- ACLI_ConnectToArduino finished.\n"; }
  }

  return $handle;
}



# This shuts down connection with an Arduino.
# Arg 0 is the SerialPort device handle for this connection.
# No return value.

sub ACLI_DisconnectArduino
{
  my ($handle);
  my ($pidlist_p);

  $handle = $_[0];

  if (!(defined $handle))
  {
    print "### [DisconnectArduino]  Bad arguments.\n";
  }
  else
  {
    # Diagnostics.
    if ($ACLI_tattle)
    { print STDERR "-- ACLI_DisconnectArduino called.\n"; }

    $pidlist_p = $$handle{pidlist};

    kill 'HUP', @$pidlist_p;
    sleep(2);
    kill 'TERM', @$pidlist_p;
    sleep(2);
    kill 'KILL', @$pidlist_p;

    # Don't bother to wait(); it's dead very shortly.

    # Diagnostics.
    if ($ACLI_tattle)
    { print STDERR "-- ACLI_DisconnectArduino finished.\n"; }
  }
}



#
# Main Program
#


# Return true.
1;



#
# This is the end of the file.
#

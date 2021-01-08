#!/usr/bin/perl
# Attention Circuits Control Laboratory - NeurAVR helper scripts
# Helper library for talking to Womelsdorf lab "neurapp" based devices.
# Written by Christopher Thomas.
# Copyright (c) 2020 by Vanderbilt University. This work is licensed under
# the Creative Commons Attribution-ShareAlike 4.0 International License.


#
# Includes
#


use strict;
use warnings;

use Time::HiRes;



#
# Global Variables
#


# Various padding latencies.

my ($NCLI_command_delay_ms, $NCLI_serious_delay_ms);

$NCLI_command_delay_ms = 10;
$NCLI_serious_delay_ms = 100;


# Various tattle flags.

my ($NCLI_echo_commands);

$NCLI_echo_commands = 0;


# Various diagnostic tattles.

my ($NCLI_read_debug_tattle);

$NCLI_read_debug_tattle = undef;



#
# Public Functions
#


# This initializes a user-defined tattletale's state.
# Arg 0 is the base output filename to write tattletales to, or undef
# to suppress output.
# Arg 1 is the initial output counter value.
# Returns a pointer to a hash containing tattle state.

sub NCLI_NewTattleState
{
  my ($fbase, $countval, $result_p);

  $fbase = $_[0]; # May be undefined.
  $countval = $_[1];

  $result_p = { 'fbase' => undef, 'count' => 0 };

  if (!(defined $countval))
  {
    print "### [NCLI_NewTattleState]  Bad arguments.\n";
  }
  else
  {
    $result_p = { 'fbase' => $fbase, 'count' => int($countval) };
  }

  return $result_p;
}


# This modifies a user-defined tattletale's state.
# Arg 0 points to the tattle state hash to modify.
# Arg 1 is the base output filename to write tattletales to, or undef
# to suppress output.
# Arg 2 is the new output counter value, or undef to keep the old count.
# No return value.

sub NCLI_SetTattleState
{
  my ($tattle_p, $fbase, $countval);

  $tattle_p = $_[0];
  $fbase = $_[1]; # May be undefined.
  $countval = $_[2]; # May be undefined.

  if (!(defined $tattle_p))
  {
    print "### [NCLI_SetTattleState]  Bad arguments.\n";
  }
  else
  {
    $$tattle_p{'fbase'} = $fbase;
    if (defined $countval)
    { $$tattle_p{'count'} = $countval; }
  }
}



# This returns the next tattletale filename in sequence, or undef if
# tattletales are suppressed. State is then updated.
# Arg 0 points to a tattletale state hash.
# Returns a filename, or undef if suppressed.

sub NCLI_GetTattleFilename
{
  my ($tattle_p, $result);

  $tattle_p = $_[0];

  $result = undef;

  if (!(defined $tattle_p))
  {
    print "### [NCLI_GetTattleFilename]  Bad arguments.\n";
  }
  else
  {
    if (defined $$tattle_p{'fbase'})
    {
      $result =
        sprintf( '%s-%06d.txt', $$tattle_p{'fbase'}, $$tattle_p{'count'} );

      $$tattle_p{'count'}++;
    }
  }

  return $result;
}



# This saves text to the next tattle file in sequence, if the tattle is
# defined and enabled.
# Arg 0 is the tattle to write to (may be undef).
# Arg 1 is the string to write.
# No return value.

sub NCLI_WriteToTattle
{
  my ($tattle, $message);
  my ($fname);

  $tattle = $_[0];  # May be undef.
  $message = $_[1];

  if (!(defined $message))
  {
    print "### [NCLI_WriteToTattle]  Bad arguments.\n";
  }
  elsif (defined $tattle)
  {
    # This will return undef if the tattle isn't active.
    if ( defined ($fname = NCLI_GetTattleFilename($tattle)) )
    {
      NCLI_SaveText($fname, $message);
    }
  }
}



# This reads the text emitted in response to previous commands.
# With MT/nonblocking handles, it reads until no more text is present.
# With blocking handles, it pauses, emits an "IDQ" command, and then reads
# until it sees the identity string.
# The text is returned and optionally also written to a file.
# Arg 0 is a communications handle.
# Arg 1 (optional) is a delay in milliseconds (default one millisecond).
# Returns the text read, including the "IDQ" output if any.

sub NCLI_ReadPendingText
{
  my ($handle, $delay, $result);
  my ($fname);

  $handle = $_[0];
  $delay = $_[1];

  $result = '';

  if (!(defined $delay))
  { $delay = 1; }
  $delay = int($delay);

  if (!( (defined $handle) && (defined $delay) ))
  {
    print "### [NCLI_ReadPendingText]  Bad arguments.\n";
  }
  else
  {
    # A delay is sometimes needed to make sure the "IDQ" command is seen,
    # with the blocking implementation.
    if (0 < $delay)
    { Time::HiRes::usleep(1000 * $delay); }


    # Switch depending on whether we have a blocking or non-blocking handle.
    if (defined $$handle{'nonblocking'})
    {
      # Read any text we have in the buffer.
      $result = ACLI_ReadPendingText($handle);
    }
    else
    {
      # Do an "IDQ" handshake, and read text until our marker.
      ACLI_WriteSerial($handle, "IDQ\n");
      $result = ACLI_ReadSerialUntilPattern($handle, 'devicetype');
    }


    # If desired, write the text to a file as well.

    $fname = NCLI_GetTattleFilename($NCLI_read_debug_tattle);

    if (defined $fname)
    {
      # Do this silently, rather than using SaveText().
      if (!open(NCLIOFILE, ">$fname"))
      {
        print "### [NCLI_ReadPendingText]  Unable to write to \"$fname\".\n";
      }
      else
      {
        print NCLIOFILE $result;
        close(NCLIOFILE);
      }
    }
  }

  return $result;
}



# This sets flags indicating whether or not to tattle "NCLI_Read" operations.
# Arg 0 is the base filename for output tattling, or undef for no tattling.
# Arg 1 is the new value for the tattle count, or undef to keep the old count.
# No return value.

sub NCLI_SetReadTattle
{
  my ($obase, $count);

  $obase = $_[0];
  $count = $_[1];

  # Both arguments may be undef.

  # Wrap the helper function for this.
  NCLI_SetTattleState($NCLI_read_debug_tattle, $obase, $count);

  # Done.
}



# This does a brute force "read until you see this pattern", with retries,
# using a keepalive command. The default delay is used.
# Arg 0 is a communications handle.
# Arg 1 is the pattern to look for.
# Returns all text received (concatenated results of each attempt).

sub NCLI_ReadUntilPattern_Seriously
{
  my ($handle, $pattern, $result);

  $handle = $_[0];
  $pattern = $_[1];

  $result = '';

  if (!( (defined $handle) && (defined $pattern) ))
  {
    print "### [NCLI_ReadUntilPattern_Seriously]  Bad arguments.\n";
  }
  else
  {
    $result .= ACLI_ReadSerialUntilPattern($handle, $pattern);

    while (!( $result =~ m/$pattern/msi ))
    {
      # If this failed, we've already timed out once, so a modest delay
      # is okay.
      Time::HiRes::usleep(1000 * 100);
      ACLI_WriteSerial($handle, "IDQ\n");
      Time::HiRes::usleep(1000 * 100);
      $result .= ACLI_ReadSerialUntilPattern($handle, 'devicetype');
    }
  }

  return $result;
}



# This writes the specified text to a file with the specified name.
# A progress message is also printed.
# Arg 0 is the filename to write to.
# Arg 1 is the text to write.
# No return value.

sub NCLI_SaveText
{
  my ($fname, $message);

  $fname = $_[0];
  $message = $_[1];

  if (!( (defined $fname) && (defined $message) ))
  {
    print "### [NCLI_SaveText]  Bad arguments.\n";
  }
  elsif (!open(NCLIOFILE, ">$fname"))
  {
    print "### [NCLI_SaveText]  Unable to write to \"$fname\".\n";
  }
  else
  {
    print NCLIOFILE $message;
    close(NCLIOFILE);

    print "-- Wrote \"$fname\".\n";
  }
}



# This waits briefly, then transmits a string to the serial device. The string
# is optionally echoed to STDOUT and optionally logged to a file.
# Arg 0 is a communications handle.
# Arg 1 is the string to send.
# No return value.

sub NCLI_SendCommand
{
  my ($handle, $message);

  $handle = $_[0];
  $message = $_[1];

  if (!( (defined $handle) && (defined $message) ))
  {
    print "### [NCLI_SendCommand]  Bad arguments.\n";
  }
  else
  {
    # Wait for the specified delay.
    if (0 < $NCLI_command_delay_ms)
    { Time::HiRes::usleep(int(1000 * $NCLI_command_delay_ms)); }

    # Tattle if desired. Messages should already have newlines appended.
    if ($NCLI_echo_commands)
    { print "*** $message"; }

    # Send the command.
    ACLI_WriteSerial($handle, $message);
  }
}



# This sends a list of commands to the Burst Box.
# Commands are newline-delimited. Anything after a # is a comment.
# Lines without text (after comments are stripped) are suppressed.
# Arg 0 is the communications handle.
# Arg 1 is a string containing commands.
# No return value.

sub NCLI_SendCommandList
{
  my ($handle, $rawlist);
  my (@cmdlist, $thisline);

  $handle = $_[0];
  $rawlist = $_[1];

  if (!( (defined $handle) && (defined $rawlist) ))
  {
    print "### [NCLI_SendCommandList]  Bad arguments.\n";
  }
  else
  {
    @cmdlist = split(/^/m, $rawlist);

    foreach $thisline (@cmdlist)
    {
      chomp($thisline);

      # Remove comments.
      if ($thisline =~ m/(.*?)#/)
      { $thisline = $1; }

      # Remove whitespace.
      if ($thisline =~ m/^\s*(.*?)\s*$/)
      { $thisline = $1; }

      # Send the command, if we have one.
      if ($thisline =~ m/\S/)
      {
        NCLI_SendCommand($handle, $thisline . "\n");
      }
    }
  }
}



# This sets the command transmission delay for NCLI_SendCommand().
# Arg 0 is the new delay in milliseconds.
# No return value.

sub NCLI_SetCommandDelay
{
  my ($newdelay);

  $newdelay = $_[0];

  if (!(defined $newdelay))
  {
    print "### [NCLI_SetCommandDelay]  Bad arguments.\n";
  }
  else
  {
    $NCLI_command_delay_ms = int($newdelay);
  }
}



# This sets the command echo flag for NCLI_SendCommand().
# Arg 0 is the new flag state (1 = echo, 0 = no echo).
# No return value.

sub NCLI_SetCommandEcho
{
  my ($newflag);

  $newflag = $_[0];

  if (!(defined $newflag))
  {
    print "### [NCLI_SetCommandEcho]  Bad arguments.\n";
  }
  else
  {
    $NCLI_echo_commands = 0;
    if ($newflag)
    { $NCLI_echo_commands = 1; }
  }
}



# This sends a command, tries very hard to find the desired response,
# and complains if it doesn't find the response. This is a pattern we use
# a lot for reading configuration and buffer information.
# Two result strings are generated - one containing all text received, and
# another containing only the text from command to pattern (inclusive).
# NOTE - The "command" text is only present if command echoing is on!
# Arg 0 is the communications handle.
# Arg 1 is the command to issue.
# Arg 2 is the pattern to look for.
# Arg 3 is the error message to send on failure (undef for none).
# Arg 4 is a tattle to write returned text to (undef for none).
# Returns (all text, bracketed text). Bracketed is undef on match failure.

sub NCLI_QueryApp_Seriously
{
  my ($handle, $cmd, $delay, $pattern, $message, $tattle);
  my ($rawtext, $matchtext);
  my ($matchpattern);
  my ($fname);

  $handle = $_[0];
  $cmd = $_[1];
  $pattern = $_[2];
  $message = $_[3]; # May be undefined.
  $tattle = $_[4]; # May be undefined.

  $rawtext = undef;
  $matchtext = undef;

  if (!( (defined $handle) && (defined $cmd) && (defined $pattern) ))
  {
    print "### [NCLI_QueryApp_Seriously]  Bad arguments.\n";
  }
  else
  {
    if (0 < $NCLI_serious_delay_ms)
    { Time::HiRes::usleep(int(1000 * $NCLI_serious_delay_ms)); }

    # Discard whatever this reads.
    NCLI_ReadPendingText($handle);

    NCLI_SendCommand($handle, $cmd);

    $rawtext = NCLI_ReadUntilPattern_Seriously($handle, $pattern);

    # Match the smallest acceptable substring.
    $matchpattern = $cmd;
    if ($matchpattern =~ m/(\S.*\S)/)
    { $matchpattern = $1; }
    $matchpattern = '.*(' . $matchpattern . '.*?' . $pattern . '.*?$)';
    $matchtext = undef;

    if ($rawtext =~ m/$matchpattern/msi)
    {
      $matchtext = $1;
    }
    else
    {
      # FIXME - Diagnostics.
#      print STDERR "... Failed to match \"$matchpattern\" in:\n";
#      print STDERR $rawtext;

      # Write the match failure message if we have one.
      if (defined $message)
      { print $message; }
    }

    # Write to the tattle if we have one.
    if (defined $tattle)
    {
      if (defined $matchtext)
      { NCLI_WriteToTattle($tattle, $matchtext); }
      else
      { NCLI_WriteToTattle($tattle, $rawtext); }
    }
  }

  return ($rawtext, $matchtext);
}



# This sets the command transmission delay for NCLI_QueryApp_Seriously().
# Arg 0 is the new delay in milliseconds.
# No return value.

sub NCLI_SetQueryDelay
{
  my ($newdelay);

  $newdelay = $_[0];

  if (!(defined $newdelay))
  {
    print "### [NCLI_SetQueryDelay]  Bad arguments.\n";
  }
  else
  {
    $NCLI_serious_delay_ms = int($newdelay);
  }
}



# This connects to a NeurAVR device, using reasonable default settings.
# Arg 0 is a serial device name (for a serial connection), undef to
#   use the first detected serial device, or an emulator filename.
# Arg 1 is a baud rate (for a serial connection) or 'emulated' for emulation.
# Arg 2 is a string containing zero or more newline-delimited startup commands.
# Arg 3 is a string containing a reporting name for this device (may be undef).
# Returns a communications handle.

sub NCLI_ConnectToNeurAVR
{
  my ($devfile, $baud, $commandlist, $name);
  my ($send_delay_ms, $serious_delay_ms, $read_timeout_secs);
  my ($handle);

  $devfile = $_[0];  # May be undef.
  $baud = $_[1];
  $commandlist = $_[2];
  $name = $_[3];  # May be undef.

  $handle = undef;

  if (!( (defined $baud) && (defined $commandlist) ))
  {
    print "### [NCLI_ConnectToNeurAVR]  Bad arguments.\n";
  }
  else
  {
    if (!(defined $name))
    { $name = 'device'; }


    if (!(defined $devfile))
    { $devfile = ACLI_AutoDetectSerialDevice(); }

    if ('emulated' eq $baud)
    {
      $send_delay_ms = 1;
      $serious_delay_ms = 10;
      $read_timeout_secs = 1;
    }
    else
    {
      $send_delay_ms = 100;
      $serious_delay_ms = 100;
      $read_timeout_secs = 5;
    }


    ACLI_SetThrottle(1);

    print "-- Connecting to $name on port $devfile at $baud bps...\n";
    $handle = ACLI_ConnectToArduino($devfile, $baud);

    if (!(defined $handle))
    {
      print "### Connection failed!\n";
    }
    else
    {
      print "-- Connected.\n";

      ACLI_SetTimeout($read_timeout_secs, "### Read timed out.\n");

      NCLI_SetCommandEcho(0);
      NCLI_SetCommandDelay($send_delay_ms);
      NCLI_SetQueryDelay($serious_delay_ms);

      NCLI_ReadPendingText($handle);

      NCLI_SendCommandList($handle, $commandlist);
    }
  }

  return $handle;
}



#
# Main Program
#


# Initialization.

$NCLI_read_debug_tattle = NCLI_NewTattleState(undef, 0);


# Return true.
1;



#
# This is the end of the file.
#

#!/usr/bin/perl
# Attention Circuits Control Laboratory - Tabular data helper scripts
# Helper library for dealing with tabular and CSV data.
# Written by Christopher Thomas.
# Copyright (c) 2020 by Vanderbilt University. This work is licensed under
# the Creative Commons Attribution-ShareAlike 4.0 International License.


#
# Includes
#

use strict;
use warnings;

use Scalar::Util;

# FIXME - Diagnostics.
use Carp;


#
# Global Variables
#



#
# Functions
#


# This applies a transformation function to an array of values.
# Arg 0 points to the input data series.
# Arg 1 points to the function to apply (taking one arg, returning one value).
# Returns a pointer to a new data series with the transformation applied.

sub TAB_ApplyFunction_Series
{
  my ($indata_p, $transfunc_p, $newdata_p);
  my ($thisval, $sidx);

  $indata_p = $_[0];
  $transfunc_p = $_[1];

  $newdata_p = [];

  if (!( (defined $indata_p) && (defined $transfunc_p) ))
  {
    print "### [TAB_ApplyFunction_Series]  Bad arguments.\n";
  }
  elsif ('CODE' ne ref($transfunc_p))
  {
    print "### [TAB_ApplyFunction_Series]  Bad function pointer.\n";
    # NOTE - This only works with "use Carp".
    # It causes an immediate exit (use "cluck" instead of "confess" to avoid).
    confess("[TAB_ApplyFunction_Series]  Bad function pointer.");
  }
  else
  {
    # Don't use "foreach"; that works by reference, rather than by value.
    for ($sidx = 0; defined ($thisval = $$indata_p[$sidx]); $sidx++)
    {
      $thisval = $transfunc_p->($thisval);
      $$newdata_p[$sidx] = $thisval;
    }
  }

  return $newdata_p;
}



# This applies a transformation function to some or all columns in a table.
# Arg 0 points to the input data table.
# Arg 1 points to the function to apply (taking one arg, returning one value).
# Arg 2 points to an array of column labels, or undef to modify all columns.
# Returns a pointer to a new data table with scaling and offset applied.
# All columns are copied, but only the specified columns are modified.

sub TAB_ApplyFunction_Table
{
  my ($indata_p, $transfunc_p, $columns_p, $newdata_p);
  my (%columnlut, $thislabel, $oldseries_p, $newseries_p);

  $indata_p = $_[0];
  $transfunc_p = $_[1];
  $columns_p = $_[2];  # May be undef.

  $newdata_p = {};

  if (!( (defined $indata_p) && (defined $transfunc_p) ))
  {
    print "### [TAB_ApplyFunction_Table]  Bad arguments.\n";
  }
  else
  {
    # If we weren't given a list of column labels, make one.
    if (!(defined $columns_p))
    {
      $columns_p = [];
      @$columns_p = keys %$indata_p;
    }

    # Turn the column list into a hash so we can easily search it.
    %columnlut = ();
    foreach $thislabel (@$columns_p)
    { $columnlut{$thislabel} = 1; }


    # Iterate through the table columns.
    foreach $thislabel (keys %$indata_p)
    {
      $oldseries_p = $$indata_p{$thislabel};
      $newseries_p = undef;

      if (defined $columnlut{$thislabel})
      {
        # Translate this series.
        $newseries_p = TAB_ApplyFunction_Series($oldseries_p, $transfunc_p);
      }
      else
      {
        # Copy by value.
        $newseries_p = [];
        @$newseries_p = @$oldseries_p;
      }

      # Store the new series.
      $$newdata_p{$thislabel} = $newseries_p;
    }

    # Done.
  }

  return $newdata_p;
}



# This applies a gain and offset to an array of values.
# Arg 0 points to the input data series.
# Arg 1 is an offset to apply before scaling.
# Arg 2 is a scale factor to apply.
# Arg 3 is an offset to apply after scaling.
# Returns a pointer to a new data series with scaling and offset applied.

sub TAB_ApplyGainOffset_Series
{
  my ($indata_p, $preshift, $scale, $postshift, $newdata_p);

  $indata_p = $_[0];
  $preshift = $_[1];
  $scale = $_[2];
  $postshift = $_[3];

  $newdata_p = [];

  if (!( (defined $indata_p) && (defined $preshift) && (defined $scale)
    && (defined $postshift) ))
  {
    print "### [TAB_ApplyGainOffset_Series]  Bad arguments.\n";
  }
  else
  {
    $newdata_p = TAB_ApplyFunction_Series($indata_p,
      sub
      {
        # FIXME - No error checking! Should have already been checked.
        my ($thisval);
        $thisval = $_[0];
        $thisval += $preshift;
        $thisval *= $scale;
        $thisval += $postshift;
        return $thisval;
      }
      );
  }

  return $newdata_p;
}



# This applies a gain and offset to some or all columns in a data table.
# Arg 0 points to the input data table.
# Arg 1 is an offset to apply before scaling.
# Arg 2 is a scale factor to apply.
# Arg 3 is an offset to apply after scaling.
# Arg 4 points to an array of column labels, or undef to modify all columns.
# Returns a pointer to a new data table with scaling and offset applied.
# All columns are copied, but only the specified columns are modified.

sub TAB_ApplyGainOffset_Table
{
  my ($indata_p, $preshift, $scale, $postshift, $columns_p, $newdata_p);

  $indata_p = $_[0];
  $preshift = $_[1];
  $scale = $_[2];
  $postshift = $_[3];
  $columns_p = $_[4];  # May be undef.

  $newdata_p = {};

  if (!( (defined $indata_p) && (defined $preshift) && (defined $scale)
    && (defined $postshift) ))
  {
    print "### [TAB_ApplyGainOffset_Table]  Bad arguments.\n";
  }
  else
  {
    $newdata_p = TAB_ApplyFunction_Table($indata_p,
      sub
      {
        # FIXME - No error checking! Should have already been checked.
        my ($thisval);
        $thisval = $_[0];
        $thisval += $preshift;
        $thisval *= $scale;
        $thisval += $postshift;
        return $thisval;
      },
      $columns_p );
  }

  return $newdata_p;
}



# This converts an unsigned 16-bit value to a signed integer value in the
# range -32k..+32k. Floating-point values are truncated; values outside the
# range 0..64k are mapped to values in range.
# This is suitable for passing to TAB_ApplyFunction_.
# Arg 0 is the unsigned 16-bit value to convert.
# Returns a signed integer value.

sub TAB_UInt16ToSigned
{
  my ($thisval);

  $thisval = $_[0];

  # FIXME - Don't report errors; just handle them.
  if (!(defined $thisval))
  { $thisval = 0; }

  $thisval = int($thisval);

  $thisval &= 0xffff;

  if ($thisval >= 0x8000)
  { $thisval -= 0x10000; }

  return $thisval;
}



# This converts a signed integer in the range -32k..+32k to an unsigned
# 16-bit value. Floating-point values are truncated; values outside the range
# -32k..+32k are mapped to values in range.
# This is suitable for passing to TAB_ApplyFunction_.
# Arg 0 is the signed 16-bit value to convert.
# Returns an unsigned integer value.

sub TAB_SignedToUInt16
{
  my ($thisval);

  $thisval = $_[0];

  # FIXME - Don't report errors; just handle them.
  if (!(defined $thisval))
  { $thisval = 0; }

  $thisval = int($thisval);

  $thisval &= 0xffff;

  return $thisval;
}



# This converts an unsigned 32-bit value to a signed integer value in the
# range -2G..+2G. Floating-point values are truncated; values outside the
# range 0..4G are mapped to values in range.
# This is suitable for passing to TAB_ApplyFunction_.
# Arg 0 is the unsigned 32-bit value to convert.
# Returns a signed integer value.

sub TAB_UInt32ToSigned
{
  my ($thisval);

  $thisval = $_[0];

  # FIXME - Don't report errors; just handle them.
  if (!(defined $thisval))
  { $thisval = 0; }

  $thisval = int($thisval);

  $thisval &= 0xffffffff;

  # FIXME - Do this the slower way that's 32-bit safe.
  if ($thisval >= 0x80000000)
  {
    $thisval = ~$thisval;
    $thisval++;
    $thisval &= 0xffffffff;
  }

  return $thisval;
}



# This converts a signed integer in the range -2G..+2G to an unsigned
# 32-bit value. Floating-point values are truncated; values outside the range
# -2G..+2G are mapped to values in range.
# This is suitable for passing to TAB_ApplyFunction_.
# Arg 0 is the signed 32-bit value to convert.
# Returns an unsigned integer value.

sub TAB_SignedToUInt32
{
  my ($thisval);

  $thisval = $_[0];

  # FIXME - Don't report errors; just handle them.
  if (!(defined $thisval))
  { $thisval = 0; }

  $thisval = int($thisval);

  $thisval &= 0xffffffff;

  return $thisval;
}



# This rounds a floating-point value to the nearest integer value.
# This is suitable for passing to TAB_ApplyFunction_.
# NOTE - This shouldn't usually be needed.
# Arg 0 is the value to round.
# Returns an integer value.

sub TAB_RoundFloat
{
  my ($thisval);

  # FIXME - Don't report errors; just handle them.
  if (!(defined $thisval))
  { $thisval = 0; }

  # Note that Perl rounds towards zero, rather than using floor().
  # We're going to end up with +0.5 rounding up and -0.5 rounding down, but
  # that's tolerable.
  if (0 <= $thisval)
  { $thisval = int($thisval + 0.5); }
  else
  { $thisval = int($thisval - 0.5); }

  return $thisval;
}



# This writes tabular data to a CSV file.
# Only the specified columns are written, in the order specified. If the
# column label list is undef, all columns are written in arbitrary order.
# Arg 0 is the name of the file to write to.
# Arg 1 points to an array of labels indicating columns to write, in order.
# Arg 2 points to a hash of column data series, indexed by label.
# No return value.

sub TAB_WriteCSVFile
{
  my ($oname, $labels_p, $table_p);
  my ($cidx, $thislabel, $thiscol_p);
  my ($sidx, $thisval, $found);
  my ($thisline);

  $oname = $_[0];
  $labels_p = $_[1];  # May be undef.
  $table_p = $_[2];

  if (!( (defined $oname) && (defined $table_p) ))
  {
    print "### [TAB_WriteCSVFile]  Bad arguments.\n";
  }
  elsif (!open(TABOFILE, ">$oname"))
  {
    print "### [TAB_WriteCSVFile]  Unable to write to \"$oname\".\n";
  }
  else
  {
    # Banner.
    print "-- Writing \"$oname\".\n";


    # If we don't have column headings, use all columns.
    # Sort these, to give a consistent order.
    if (!(defined $labels_p))
    {
      $labels_p = [];
      @$labels_p = sort keys %$table_p;
    }


    # Write column headings.

    for ($cidx = 0; defined ($thislabel = $$labels_p[$cidx]); $cidx++)
    {
      if (0 < $cidx)
      { print TABOFILE ','; }

      print TABOFILE ("\"$thislabel\"");
    }

    print TABOFILE "\n";


    # Write data columns.
    # NOTE - These are not guaranteed to be the same length!

    $found = 1;
    for ($sidx = 0; $found; $sidx++)
    {
      $found = 0;
      $thisline = '';

      for ($cidx = 0; defined ($thislabel = $$labels_p[$cidx]); $cidx++)
      {
        if (0 < $cidx)
        { $thisline .= ','; }

        $thiscol_p = $$table_p{$thislabel};

        # Handle bogus labels gracefully.
        if (defined $thiscol_p)
        {
          if (defined ($thisval = $$thiscol_p[$sidx]))
          {
            $found = 1;

            # Special-case text strings vs numbers.
            if (Scalar::Util::looks_like_number($thisval))
            { $thisline .= sprintf('%.6f', $thisval); }
            else
            { $thisline .= '"'.$thisval.'"'; }
          }
        }
      }

      $thisline .= "\n";

      # Only emit the line if we had at least one non-empty column.
      if ($found)
      { print TABOFILE $thisline; }
    }


    # Done.
    close(TABOFILE);
  }
}



# This reads tabular data from a CSV file.
# Each column is assumed to begin with a label string. The series are
# returned as a pointer to a hash of arrays, containing data series indexed
# by label. A pointer to an array containing an ordered list of labels is
# also returned.
# Behavior with sparse data (missing cells, rows, or columns) is undefined.
# Arg 0 is the name of the file to read from.
# Returns (labels, series_hash).

sub TAB_ReadCSVFile
{
  my ($cname, $labels_p, $table_p);
  my ($thisline, @cells, $thiscell, $cidx);
  my ($thislabel, $thiscol_p);

  $cname = $_[0];

  $labels_p = [];
  $table_p = {};

  if (!(defined $cname))
  {
    print "### [TAB_ReadCSVFile]  Bad arguments.\n";
  }
  elsif (!open(TABCFILE, "<$cname"))
  {
    print "### [TAB_ReadCSVFile]  Unable to read from \"$cname\".\n";
  }
  else
  {
    # Banner.
    print "-- Reading \"$cname\".\n";


    while (defined ($thisline = <TABCFILE>))
    {
      @cells = split(/,/, $thisline);

      for ($cidx = 0; defined ($thiscell = $cells[$cidx]); $cidx++)
      {
        chomp($thiscell);

        if ($thiscell =~ m/\"(.*)\"/)
        {
          # This cell has a string.
          # If we don't have a column label yet, treat it as a label.
          # Otherwise treat it as a cell value.

          $thislabel = $$labels_p[$cidx];

          if (!(defined $thislabel))
          { $$labels_p[$cidx] = $1; }
          else
          {
            # Make sure we have a data array for this column.
            if (!( defined ($thiscol_p = $$table_p{$thislabel}) ))
            {
              $thiscol_p = [];
              $$table_p{$thislabel} = $thiscol_p;
            }

            # Store the string without enclosing " marks.
            push @$thiscol_p, $1;
          }
        }
        elsif ($thiscell =~ m/\S/)
        {
          # This cell has something we're interpreting as a data value.

          # Make sure we have a label for this column. Make one if necessary.
          if (!(defined $$labels_p[$cidx]))
          { $$labels_p[$cidx] = "column $cidx"; }

          $thislabel = $$labels_p[$cidx];

          # Make sure we have a data array for this column.
          if (!( defined ($thiscol_p = $$table_p{$thislabel}) ))
          {
            $thiscol_p = [];
            $$table_p{$thislabel} = $thiscol_p;
          }

          # Force interpretation of the cell value as a number, and add it.
          push @$thiscol_p, (1.0 * $thiscell);
        }
      }
    }

    # Done.
    close(TABCFILE);
  }

  return ($labels_p, $table_p);
}



# This adds a child tabular data hash into a parent tabular data hash.
# A single line is added to the parent, representing aggregate values from
# the child. For each column in the child, row values are either summed or
# averaged to get the aggregate value for that column.
# A "label" column in the parent records a label associated with each child.
# Any "label" column in the child is discarded, as a special case.
# Arg 0 points to the parent tabular data hash to merge with, which may be
# an empty hash.
# Arg 1 is a label to associate with this child's aggregate data.
# Arg 2 points to the child tabular data hash to add.
# Arg 3 is an aggregation method ('sum', 'mean').
# No return value.

sub TAB_TableAddChildAsAggregate
{
  my ($parent_p, $rowlabel, $child_p, $method);
  my ($totals_p, $thislabel, $thisseries_p, $thisval);
  my ($count, $thistotal);

  $parent_p = $_[0];
  $rowlabel = $_[1];
  $child_p = $_[2];
  $method = $_[3];

  if (!( (defined $parent_p) && (defined $rowlabel) && (defined $child_p)
    && (defined $method) ))
  {
    print "### [TAB_TableAddChildAsAggregate]  Bad arguments.\n";
  }
  elsif (!( ('sum' eq $method) || ('mean' eq $method) ))
  {
    print "### [TAB_TableAddChildAsAggregate]  Unknown method \"$method\".\n";
  }
  else
  {
    #
    # First pass: Get aggregate totals from the child.

    $totals_p = {};
    foreach $thislabel (keys %$child_p)
    {
      if ('label' ne $thislabel)
      {
        $$totals_p{$thislabel} = 0;
        $thisseries_p = $$child_p{$thislabel};

        $count = 0;
        $thistotal = 0;

        foreach $thisval (@$thisseries_p)
        {
          $thistotal += $thisval;
          $count++;
        }

        if ( ('mean' eq $method) && (0 < $count) )
        { $thistotal /= $count; }

        $$totals_p{$thislabel} = $thistotal;
      }
    }


    #
    # Second pass: Add this row to the parent.

    if (!(defined $$parent_p{'label'}))
    {
      # The parent' doesn't have a "label" field.
      # Assume this is a new parent hash, and initialize all columns.
      $$parent_p{'label'} = [ $rowlabel ];
      foreach $thislabel (keys %$totals_p)
      { $$parent_p{$thislabel} = [ $$totals_p{$thislabel} ]; }
    }
    else
    {
      # Adding data to an existing hash.

      $thisseries_p = $$parent_p{'label'};
      push @$thisseries_p, $rowlabel;

      foreach $thislabel (keys %$totals_p)
      {
        $thisval = $$totals_p{$thislabel};
        $thisseries_p = $$parent_p{$thislabel};

        if (!(defined $thisseries_p))
        {
          print "### [TAB_TableAddChildAsAggregate]  "
            . "Column \"$thislabel\" in child not found in parent.\n";
        }
        else
        { push @$thisseries_p, $thisval; }
      }
    }
  }
}



# This adds one row of tabular data into a parent tabular data hash.
# The row data consists of a hash of scalar values (i.e. it is not itself
# a tabular data hash).
# If a "label" argument is provided, the "label" field in this row of data
# set to the specified value (overwriting any such value from the added row).
# Behavior with sparse data (missing cells, rows, or columns) is undefined.
# Arg 0 points to the parent tabular data hash to add to, which may be
# an empty hash.
# Arg 1 points to a hash containing data values for the row to be added.
# Arg 2 is a label to associate with the new row, or undef for no label.
# No return value.

sub TAB_TableAddRow
{
  my ($parent_p, $rowdata_p, $label);
  my ($thiskey, $thislist_p);

  $parent_p = $_[0];
  $rowdata_p = $_[1];
  $label = $_[2];  # May be undef.

  if (!( (defined $parent_p) && (defined $rowdata_p) ))
  {
    print "### [TAB_TableAddRow]  Bad arguments.\n";
  }
  else
  {
    # First, add the data.
    # If there's a "label" field, skip it if we were given a label.
    foreach $thiskey (keys %$rowdata_p)
    {
      if (!(defined $$parent_p{$thiskey}))
      { $$parent_p{$thiskey} = []; }

      $thislist_p = $$parent_p{$thiskey};
      if (!( (defined $label) && ($thiskey eq 'label') ))
      { push @$thislist_p, $$rowdata_p{$thiskey}; }
    }

    # Next, set the "label" field if we were given a label.
    if (defined $label)
    {
      if (!(defined $$parent_p{'label'}))
      { $$parent_p{'label'} = []; }

      $thislist_p = $$parent_p{'label'};
      push @$thislist_p, $label;
    }
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

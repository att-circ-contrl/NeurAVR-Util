# Attention Circuits Control Laboratory - Perl libraries for NeurAVR devices
# README documentation.
Written by Christopher Thomas.


## Contents

* `ardclient-lib-mt.pl` --
Low-level communications functions for talking to USB serial devices such as
Arduino boards. Multithreaded version with a read buffer.

* `neuroclient-lib.pl` --
Higher-level communications functions for talking to USB serial devices
running NeurAVR firmware (in particular those that support the application
skeleton's built-in commands).

* `tabular-lib.pl` --
Functions for manipulating tables of numeric data, and for reading and
writing table data (numbers or strings) as CSV files.

* `ardclient-funcs.txt`, `neuroclient-funcs.txt`, `tabular-funcs.txt` --
Automatically generated documentation (compilation of appropriate in-library
comment blocks).

* `makedocs.sh` -- Script for rebuilding documentation.


## Notes

* Several project-specific libraries (such as Burst Box and Digi-Box
utility libraries) use functions provided by these libraries.


_This is the end of the file._

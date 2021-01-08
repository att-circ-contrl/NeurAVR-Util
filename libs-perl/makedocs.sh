#!/bin/bash

for F in ardclient neuroclient tabular
do
  document-perl $F*pl > $F-funcs.txt
done

# This is the end of the file.

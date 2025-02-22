#TODO:
# R sort scripts samenvoegen met argumenten
# Sinvict to vcf. py Write loopjes in functie
# Default values for parameters (if argument is given > overwrite..
# Filter Lofreq functie


while getopts "R:L:I:O:V:D:C:P:" arg; do
  case $arg in
    R) Reference=$OPTARG;;      # "/apps/data/1000G/phase1/human_g1k_v37_phiX.fasta"
    L) Listregions=$OPTARG;;    # "/groups/umcg-pmb/tmp01/projects/hematopathology/Lymphoma/Nick/2020_covered_probe_notranslocation.bed"
    I) Inputbam=$OPTARG;;       # "/groups/umcg-pmb/tmp01/projects/hematopathology/Lymphoma/GenomeScan_SequenceData/103584/"
    O) Outputdir=$OPTARG;;
    V) VAF=$OPTARG;;            # 0.004
    D) RDP=$OPTARG;;            # 100
    C) Calls=$OPTARG;;          # 1
    P) PoN=$OPTARG;;            # "/groups/umcg-pmb/tmp01/projects/hematopathology/Lymphoma/GenomeScan_SequenceData/104103_normals/"
  esac
done

cd /groups/umcg-pmb/tmp01/projects/hematopathology/Lymphoma/Nick/SNVcallingPipeline/

echo -e "\nSettings: \n\nInput bam(s): $Inputbam \nReference: $Reference \nPanel: $Listregions\nminimum VAF: $VAF\nminimum Read Depth: $RDP\nminimum overlapping calls: $Calls\nPoN:$PoN"
echo -e '\nLoading modules: \n'
module load GATK/4.1.4.0-Java-8-LTS
module load SAMtools/1.9-GCCcore-7.3.0
module load BCFtools/1.11-GCCcore-7.3.0
module load HTSlib/1.11-GCCcore-7.3.0
module load Python/3.9.1-GCCcore-7.3.0-bare
module load R/4.0.3-foss-2018b-bare
module list

mkdir ./output

postprocess_vcf() {
  Input=$1
  ./tools/vt/vt decompose -s -o $(dirname $Input)/$(basename $Input .vcf)-decomposed.vcf ${Input}
  ./tools/vt/vt normalize -q -n -m -o $(dirname $Input)/$(basename $Input .vcf)-decomposed-normalized.vcf -r $Reference $(dirname $Input)/$(basename $Input .vcf)-decomposed.vcf
  bgzip $(dirname $Input)/$(basename $Input .vcf)-decomposed-normalized.vcf
  bcftools index $(dirname $Input)/$(basename $Input .vcf)-decomposed-normalized.vcf.gz
}

pythonscript() {
  source ./env/bin/activate
  python3 $1 $2 $3 $4 $5
  deactivate
}

annotate() {
  source ./env/bin/activate
  oc run $1 \
    -l hg19 \
    -n $2 --silent \
    -a clinvar civic cgc cgl cadd cancer_genome_interpreter cancer_hotspots chasmplus chasmplus_DLBC chasmplus_DLBC_mski \
       clinpred cosmic cscape dbsnp gnomad mutation_assessor thousandgenomes vest cadd_exome gnomad3 thousandgenomes_european \
    -t excel
  deactivate 
}

mutect() { # $1 = sample, $2 = output, $3 = bed, $4 --max-mnp-distance 0 (PoN mode)
  gatk Mutect2 \
    --verbosity ERROR \
    --callable-depth $RDP \
    --minimum-allele-fraction $VAF \
    -R $Reference \
    -I $1 \
    -O $2 \
    --native-pair-hmm-threads 9 \
    -L $3 --QUIET $4
}

filter_mutect() { # $1 = sample, $2 = output
gatk FilterMutectCalls \
  --verbosity ERROR \
  --min-allele-fraction $VAF \
  -R $Reference \
  -V $1 \
  -O $2
}

vardict() { # $1 = sample, $2 = output, $3 = bed
  ~/.conda/pkgs/vardict-java-1.8.2-hdfd78af_3/bin/vardict-java \
    -f $VAF \
    -th 9 \
    -G $Reference \
    -b $1 \
    -c 1 -S 2 -E 3 \
    $3 > $2
}

lofreq() { # $1 = sample, $2 = output, $3 = bed
  ./tools/lofreq/src/lofreq/lofreq call-parallel \
     --pp-threads 9 \
     --call-indels \
     --no-default-filter \
     -f $Reference \
     -o $2 \
     -l $3 \
     $1
}

filter_lofreq() { # $1 = sample, $2 = output
  ./tools/lofreq/src/lofreq/lofreq filter \
    -i $1 \
    -o $2 \
    -v $RDP \
    -a $VAF
}

sinvict() { # $1 = sample, $2 = output, $3 = bed, $4 temp_readcount
./tools/sinvict/bam-readcount/build/bin/bam-readcount \
  -l $3 \
  -w 1 \
  -f $Reference \
  $1 > $4/output.readcount && \
    
./tools/sinvict/sinvict \
  -m $RDP \
  -f $VAF \
  -t $4 \
  -o $2
}


create_pon() {
  echo -e "\nPoN included: source for PoN .bam files = $PoN"
  #Step 1; Tumor only mode on all normal bam files
  for entry in "$PoN"/*.bam
  do
    echo -e '\n\nGenerating VCF for normal control: '
    echo -e normalcontrol= $(basename $entry .bam) '\n'
    #Mutect2
    mutect $entry ./PoN/normal_$(basename $entry .bam)_Mutect.vcf.gz ./PoN/newbed.bed "--max-mnp-distance 0" & \
    
    #Vardict
    vardict $entry ./PoN/normal_$(basename $entry .bam)_Vardict1.vcf ./PoN/newbed.bed & \

    #Lofreq
    lofreq $entry ./PoN/normal_$(basename $entry .bam)_LofreqUnfiltered.vcf ./PoN/newbed.bed && \
    #Filter Lofreq     
    ./tools/lofreq/src/lofreq/lofreq filter \
      -i ./PoN/normal_$(basename $entry .bam)_LofreqUnfiltered.vcf \
      -o ./PoN/normal_$(basename $entry .bam)_Lofreq.vcf  \
      -v $RDP \
      -a $VAF & \
       
    #SiNVICT
    mkdir ./PoN/$(basename $entry .bam)output-readcount/ && mkdir ./PoN/$(basename $entry .bam)output-sinvict/ && \
    sinvict $entry ./PoN/$(basename $entry .bam)output-sinvict/ ./PoN/newbed.bed  ./PoN/$(basename $entry .bam)output-readcount/ && \
    rm -rf ./PoN/$(basename $entry .bam)output-readcount/ & \
    wait
    
    Rscript ./sort_vardict.R ./PoN/normal_$(basename $entry .bam)_Vardict1.vcf ./PoN/normal_$(basename $entry .bam)_Vardict2.vcf
    pythonscript ./vardict_vcf.py ./PoN/normal_$(basename $entry .bam)_Vardict2.vcf ./PoN/normal_$(basename $entry .bam)_Vardict.vcf
    Rscript ./sort_sinvict.R ./PoN/$(basename $entry .bam)output-sinvict/calls_level1.sinvict ./PoN/$(basename $entry .bam)output-sinvict/calls_level1_sorted.sinvict
    pythonscript ./create_vcf.py ./PoN/$(basename $entry .bam)output-sinvict/calls_level1_sorted.sinvict ./PoN/normal_$(basename $entry .bam)_Sinvict.vcf $Reference 'sinvict'
    
    bgzip ./PoN/normal_$(basename $entry .bam)_Vardict.vcf
    bcftools index ./PoN/normal_$(basename $entry .bam)_Vardict.vcf.gz
    bgzip ./PoN/normal_$(basename $entry .bam)_Lofreq.vcf
    bcftools index ./PoN/normal_$(basename $entry .bam)_Lofreq.vcf.gz   
    bgzip ./PoN/normal_$(basename $entry .bam)_Sinvict.vcf
    bcftools index ./PoN/normal_$(basename $entry .bam)_Sinvict.vcf.gz
  done
  
  #Step 2 merge pon data
  echo -e '\nMerging normal vcfs into GenomicsDB \n\n'
  ls ./PoN/*Mutect.vcf.gz > ./PoN/M2normals.dat
  ls ./PoN/*Vardict.vcf.gz > ./PoN/VDnormals.dat
  ls ./PoN/*Lofreq.vcf.gz > ./PoN/LFnormals.dat
  ls ./PoN/*Sinvict.vcf.gz > ./PoN/SVnormals.dat
  sed -i -e 's/^/ -V /' ./PoN/M2normals.dat
  sed -i -e 's/^/ /' ./PoN/VDnormals.dat
  sed -i -e 's/^/ /' ./PoN/LFnormals.dat
  sed -i -e 's/^/ /' ./PoN/SVnormals.dat
  xargs -a ./PoN/M2normals.dat gatk --java-options "-Xmx8g" GenomicsDBImport --verbosity ERROR --genomicsdb-workspace-path ./PoN/M2controls_pon_db_chr -R $Reference -L 1 -L 2 -L 3 -L 4 -L 5 -L 6 -L 7 -L 8 -L 9 -L 10 -L 11 -L 12 -L 13 -L 14 -L 15 -L 16 -L 17 -L 18 -L 19 -L 20 -L 21 -L 22 -L X -L Y --QUIET

  #Step 3 create merged PoN VCF file 
  echo -e '\nGenerating Panel Of Normals VCF file: \n'
  gatk --java-options "-Xmx8g" CreateSomaticPanelOfNormals \
    --verbosity ERROR -R $Reference \
    --QUIET \
    -V gendb://$PWD/PoN/M2controls_pon_db_chr \
    -O ./PoN/merged_PoN_Mutect2.vcf
  
  xargs -a ./PoN/VDnormals.dat bcftools isec -o ./PoN/Xmerged_PoN_Vardict.vcf -O v -n +2 
  xargs -a ./PoN/LFnormals.dat bcftools isec -o ./PoN/Xmerged_PoN_Lofreq.vcf -O v -n +2 
  xargs -a ./PoN/SVnormals.dat bcftools isec -o ./PoN/Xmerged_PoN_Sinvict.vcf -O v -n +2 
  echo -e '\ndecomposing and normalizing PoN VCF file: \n\n' 

  pythonscript ./create_vcf.py ./PoN/Xmerged_PoN_Vardict.vcf ./PoN/merged_PoN_Vardict.vcf $Reference 'bcftools_isec'
  pythonscript ./create_vcf.py ./PoN/Xmerged_PoN_Lofreq.vcf ./PoN/merged_PoN_Lofreq.vcf $Reference 'bcftools_isec'
  pythonscript ./create_vcf.py ./PoN/Xmerged_PoN_Sinvict.vcf ./PoN/merged_PoN_Sinvict.vcf $Reference 'bcftools_isec'
  postprocess_vcf "./PoN/merged_PoN_Vardict.vcf"
  postprocess_vcf "./PoN/merged_PoN_Lofreq.vcf"
  postprocess_vcf "./PoN/merged_PoN_Sinvict.vcf"
  postprocess_vcf "./PoN/merged_PoN_Mutect2.vcf"
  
  bcftools isec -o ./PoN/BLACKLIST.txt -O v -n +2 ./PoN/merged_PoN_Sinvict-decomposed-normalized.vcf.gz ./PoN/merged_PoN_Mutect2-decomposed-normalized.vcf.gz ./PoN/merged_PoN_Lofreq-decomposed-normalized.vcf.gz ./PoN/merged_PoN_Vardict-decomposed-normalized.vcf.gz

  #annotating the PoN blacklist  
  echo -e '\n Annotating PoN Blacklist...\n'
  annotate "./PoN/BLACKLIST.txt" "annotated_blacklist"
  echo -e '\nDone! PoN is ready for use. Now on to analyzing samples...\n\n'
}


run_tools() {
  # Creating temp dirs
  mkdir ./temp && mkdir ./temp/M2 && mkdir ./temp/VD && mkdir ./temp/LF && mkdir ./temp/SV
  mkdir ./temp/output-readcount && mkdir ./temp/output-sinvict  
  echo -e '\nPre-processing bam file... \n\n'
  ## Preprocessing .bam and (removing 'chr')
  sed 's/chr//g' $Listregions > ./temp/newbed.bed
  samtools view -H $1 | sed 's/chr//g' > ./temp/header.sam
  samtools reheader ./temp/header.sam $1 > ./temp/newbam.bam
  samtools index ./temp/newbam.bam

  ############# TOOLS: 
  echo -e '\nRunning all 4 tools simultaneously...\n'
  #Lofreq
  lofreq ./temp/newbam.bam ./temp/LF/output_lofreq_bed.vcf ./temp/newbed.bed && \
  #Filter Lofreq
  filter_lofreq ./temp/LF/output_lofreq_bed.vcf ./temp/LF/LF.vcf & \
      
  #Mutect2
  mutect ./temp/newbam.bam ./temp/M2/M2Unfiltered.vcf ./temp/newbed.bed && \
  #Filter Mutect2
  filter_mutect ./temp/M2/M2Unfiltered.vcf ./temp/M2/M2.vcf & \
    
  #VarDict
  vardict ./temp/newbam.bam ./temp/VD/vardict_raw.vcf ./temp/newbed.bed & \
    
  #SiNVICT
  sinvict ./temp/newbam.bam ./temp/output-sinvict/ ./temp/newbed.bed ./temp/output-readcount/ & \
  wait
  
  ## Processing LoFreq:
  echo -e '\n\Processing LoFreq data: \n'
  postprocess_vcf "./temp/LF/LF.vcf"
  
  ## Processing Mutect2:
  echo -e '\nProcessing Mutect2: \n'
  postprocess_vcf "./temp/M2/M2.vcf"
  
  ## Processing VarDict
  echo -e '\nProcessing Vardict data: \n'
  Rscript ./sort_vardict.R ./temp/VD/vardict_raw.vcf ./temp/VD/vardict_output_sorted.vcf
  pythonscript ./vardict_vcf.py ./temp/VD/vardict_output_sorted.vcf ./temp/VD/VD.vcf
  postprocess_vcf "./temp/VD/VD.vcf"
  
  ## Processing SiNVICT
  echo -e '\nProcessing SiNVICT data: \n'
  Rscript ./sort_sinvict.R ./temp/output-sinvict/calls_level1.sinvict ./temp/output-sinvict/calls_level1_sorted.sinvict
  pythonscript ./create_vcf.py ./temp/output-sinvict/calls_level1_sorted.sinvict ./temp/SV/SV.vcf $Reference 'sinvict'
  postprocess_vcf "./temp/SV/SV.vcf"

  wait 
  echo -e '\nData processed with all 4 tools\n'
}

process_bam() {
  a=$1
  xbase=${a##*/}
  xpref=${xbase%.*}
  echo -e "Processing sample $xpref\n"  
  run_tools $a
  mkdir ./output/${xpref} 
  echo -e '\nComparing SNV Tools: \n'
  bcftools isec \
    -p ./output/${xpref} \
    -O v \
    -n +$Calls \
    ./temp/SV/SV-decomposed-normalized.vcf.gz \
    ./temp/M2/M2-decomposed-normalized.vcf.gz \
    ./temp/LF/LF-decomposed-normalized.vcf.gz \
    ./temp/VD/VD-decomposed-normalized.vcf.gz  

  #Plotting and Annotating blacklisted SNV's
  if [ -z "$PoN" ]
  then
    echo ""
  else
    echo -e "source for PoN .bam files = $PoN \nBlacklisting...\n"
    pythonscript ./pon_blacklist.py ${xpref}
    pythonscript ./create_plots.py ${xpref} "sites_PoN.txt"

    echo 'annotating variants filterd by pon...' 
    annotate "./output/${xpref}/sites_PoN.txt" "annotated_SNVs_PoN_blacklisted"
  fi 
  
  #Plotting and Annotating SNV's   
  pythonscript ./create_plots.py ${xpref} "sites.txt"
  echo 'annotating variants...'
  annotate "./output/${xpref}/sites.txt" "annotated_SNVs"
  
  rm -rf ./temp  
  echo -e "\nAnalysis of $xpref is complete!\n\n\n"
}

# Create PoN if argument is given:
if [ -z "$PoN" ]
then
  echo -e "\nNo PoN mode\n"
else
  mkdir ./PoN/
  sed 's/chr//g' $Listregions > ./PoN/newbed.bed
  create_pon
fi

#Directory:
if [[ -d $Inputbam ]]; then
    for entry in "$Inputbam"/*.bam
    do
      process_bam $entry
    done  
#One-File:     
elif [[ -f $Inputbam ]]; then
    process_bam $Inputbam
#Else (error)
else
    echo "$Inputbam is not valid"
    exit 1
fi

echo -e '\nFinished run! \n'


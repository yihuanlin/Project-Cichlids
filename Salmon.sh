#!/bin/bash
#SBATCH --job-name=salmon_quant
#SBATCH --output=salmon_quant_%j.out
#SBATCH --error=salmon_quant_%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=64
#SBATCH --mem=128G
#SBATCH --time=48:00:00
#SBATCH --partition=compute

# https://bioinformatics-core-shared-training.github.io/Bulk_RNAseq_Course_Nov24/Bulk_RNAseq_Course_Base/Markdowns/02_FastQC_practical.html
# https://bioinformatics-core-shared-training.github.io/Bulk_RNAseq_Course_Nov24/Bulk_RNAseq_Course_Base/Markdowns/03_Quantification_with_Salmon_practical.html
species="Astatotilapia calliptera"
fq="/mnt/home3/miska/cy293/cichlids/bulk_RNA_seq/input/unstranded/*_LG_rep*"

readarray -t sample < <(ls $fq | cut -d'_' -f1)
readarray -t replicate < <(ls $fq | cut -d'_' -f3 | cut -d'.' -f1)
middle=$(echo $fq | awk -F'/' '{print $NF}' | cut -d'_' -f2)
species=$(echo "$species" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
conda activate seq || conda create -n seq biopython requests pandas ipykernel primer3-py fastqc picard salmon blast -y
cd ~/scratch/seq
mkdir -p ./fastq/
cp -n $fq ./fastq/
mkdir -p ./genome/
cd ./genome/
genome=$(curl -s https://ftp.ensembl.org/pub/current_fasta/${species}/cdna/ | grep -oP '(?<=href=")[^"]+(?=\.cdna\.all\.fa\.gz)' | head -1)
if [ ! -f ${genome}.dna_sm.toplevel.fa.gz ]; then
    wget https://ftp.ensembl.org/pub/current_fasta/${species}/dna/${genome}.dna_sm.toplevel.fa.gz
fi
if [ ! -f ${genome}.cdna.all.fa.gz ]; then
    wget https://ftp.ensembl.org/pub/current_fasta/${species}/cdna/${genome}.cdna.all.fa.gz
fi
if [ ! -f ${genome}.fa.gz ]; then
    cat ${genome}.cdna.all.fa.gz ${genome}.dna_sm.toplevel.fa.gz > ${genome}.fa.gz
fi
if [ ! -f decoy.txt ]; then
    zcat ${genome}.dna_sm.toplevel.fa.gz | grep "^>" | cut -d " " -f 1 | sed 's/>//g' > decoy.txt
fi
mkdir -p ../script/
if [ ! -f ../script/create_refflat_from_sam_header.py ]; then
    wget https://raw.githubusercontent.com/crukci-bioinformatics/BamHeaderToRefflat/refs/heads/master/create_refflat_from_sam_header.py -O ../script/create_refflat_from_sam_header.py
fi
if [ ! -d ${genome}_index ]; then
    salmon index -t ${genome}.fa.gz -d decoy.txt -p 64 -i ${genome}_index
fi
mkdir -p ../output/

for i in "${!sample[@]}"; do
    for j in "${!replicate[@]}"; do
        mkdir -p ../output/${sample[i]}_${middle}_${replicate[j]}
        if [ ! -d ../output/${sample[i]}_${middle}_${replicate[j]} ]; then
            salmon quant -i ${genome}_index -l A -1 ../fastq/${sample[i]}_${middle}_${replicate[j]}_*_1.fq.gz -2 ../fastq/${sample[i]}_${middle}_${replicate[j]}_*_2.fq.gz -p 64 -o ../output/${sample[i]}_${middle}_${replicate[j]} --writeMappings=../output/${sample[i]}_${middle}_${replicate[j]}.salmon.sam --gcBias
        fi
        cd ../output/${sample[i]}_${middle}_${replicate[j]}/
        if [ ! -f ${sample[i]}_${middle}_${replicate[j]}.salmon.bam ]; then
            samtools sort -O BAM -o ${sample[i]}_${middle}_${replicate[j]}.salmon.bam ${sample[i]}_${middle}_${replicate[j]}.salmon.sam -@ 64
        fi
        if [ ! -f ${sample[i]}_${middle}_${replicate[j]}.tsv ]; then
            ### Make transcript to gene table
            echo -e "TxID\tGeneID" > ${sample[i]}_${middle}_${replicate[j]}.tsv
            zcat ${genome}.cdna.all.fa.gz |
            grep "^>" | 
            cut -f 1,4 -d ' ' | 
            sed -e 's/^>//' -e 's/gene://' -e 's/\.[0-9]*$//' |
            tr ' ' '\t'  >> ${sample[i]}_${middle}_${replicate[j]}.tsv
        fi
        # https://bioinformatics-core-shared-training.github.io/Bulk_RNAseq_Course_Nov24/Bulk_RNAseq_Course_Base/Markdowns/04_Quality_Control_practical.html
        # samtools view -H AC_LG_rep1.salmon.bam | grep '@RG' # Get the read group information
        if [ ! -f ${sample[i]}_${middle}_${replicate[j]}.salmon.sorted.bam ]; then
            picard AddOrReplaceReadGroups \
                -I ${sample[i]}_${middle}_${replicate[j]}.salmon.bam \
                -O ${sample[i]}_${middle}_${replicate[j]}.salmon.sorted.bam \
                -RGID ${replicate[j]} \
                -RGLB lib1 \
                -RGPL illumina \
                -RGPU unit1 \
                -RGSM ${sample[i]}_${middle}_${replicate[j]} \
                -VALIDATION_STRINGENCY SILENT
        fi
        if [ ! -f ${sample[i]}_${middle}_${replicate[j]}.salmon.mkdup.bam ]; then
            picard MarkDuplicates \
                -I ${sample[i]}_${middle}_${replicate[j]}.salmon.sorted.bam \
                -O ${sample[i]}_${middle}_${replicate[j]}.salmon.mkdup.bam \
                -M ${sample[i]}_${middle}_${replicate[j]}.salmon.mkdup_metrics.txt \
                -CREATE_INDEX true \
                -VALIDATION_STRINGENCY SILENT
        fi
        if [ ! -f ../output/${genome}_transriptome_refFlat.txt ]; then
            ../../script/create_refflat_from_sam_header.py -b ${sample[i]}_${middle}_${replicate[j]}.salmon.sorted.bam -o ../output/${genome}_transriptome_refFlat.txt
        fi
        if [ ! -f ${sample[i]}_${middle}_${replicate[j]}.salmon.mkdup.metrics ]; then
            picard CollectRnaSeqMetrics \
                -I ${sample[i]}_${middle}_${replicate[j]}.salmon.mkdup.bam \
                -O ${sample[i]}_${middle}_${replicate[j]}.salmon.mkdup.metrics \
                -REF_FLAT ../output/${genome}_transriptome_refFlat.txt \
                -STRAND_SPECIFICITY NONE \
                -VALIDATION_STRINGENCY SILENT
        fi
        if [ ! -f ${sample[i]}_${middle}_${replicate[j]}.QCReport.html ]; then
            multiqc . -n ${sample[i]}_${middle}_${replicate[j]}.QCReport.html -o .
        fi
    done
done
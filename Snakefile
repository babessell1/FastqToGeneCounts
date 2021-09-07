"""
This is an attempt to convert HCC_Data/align_liver_PE.bash into a snakefile
"""

import glob
import os
import subprocess
import csv
import numpy as np
import warnings
configfile: "snakemake_config.yaml"

def get_tissue_name():
    """
    Looking to return the base filename from the controls/init_files
    Example:
    controls/init_files/naiveB_S1R1.csv
    controls/init_files/naiveB_S1R2.csv

    We would return: ["naiveB", "naiveB"]
    :return:
    """
    tissue_data = []

    with open(config["MASTER_CONTROL"], "r") as rfile:
        reader = csv.reader(rfile)
        for i, line in enumerate(reader):
            id = line[1].split("_")[0]  # naiveB_S1R1 -> naiveB
            pe_se = line[2]

            # append tissue name twice of paired end, allows for naming "_1" and "_2"
            if pe_se == "PE":
                tissue_data.append(id)
                tissue_data.append(id)
            elif pe_se == "SE":
                tissue_data.append(id)

    return tissue_data

def get_tag_data():
    """
    Return tag from cell ID
    Example:
        input: naiveB_S1R1
        output: S1R1
    :return:
    """
    tag_data = []
    with open(config["MASTER_CONTROL"], "r") as rfile:
        reader = csv.reader(rfile)
        for i, line in enumerate(reader):
            tag = line[1].split("_")[-1]
            pe_se = line[2]

            # append tag twice for paired end, allows for naming "_1" and "_2"
            if pe_se == "PE":
                tag_data.append(tag)
                tag_data.append(tag)
            elif pe_se == "SE":
                tag_data.append(tag)
    return tag_data

def get_srr_data():
    """
    Get the SRR information from the master init_file
    Example:
        input:
            SRR14231328,naiveB_S1R1,PE
            SRR14231329,naiveB_S1R2,PE
        output: ["SRR14231329", "SRR14231328"]

    :return:
    """
    srr_data = []
    with open(config["MASTER_CONTROL"], "r") as rfile:
        reader = csv.reader(rfile)
        for line in reader:
            srr = line[0]
            pe_se = line[2]

            if pe_se == "PE":
                srr_data.append(srr)
                srr_data.append(srr)
            elif pe_se == "SE":
                srr_data.append(srr)
    return srr_data

def get_PE_SE_Data():
    """
    This function will read from the config[MASTER_CONTROL] file and return the paired_end or single_end variable
    Example:
        input:
            SRR14231328,naiveB_S1R1,PE
            SRR14231329,naiveB_S1R2,SE
        output:
            ["_1", "_2", "_s"]
            # PE,   PE,   SE
    :return:
    """
    pe_se_data = []
    with open(config["MASTER_CONTROL"], "r") as rfile:
        reader = csv.reader(rfile)
        for line in reader:
            pe_se = line[2]
            if pe_se == "PE":
                pe_se_data.append("1")
                pe_se_data.append("2")
            elif pe_se == "SE":
                pe_se_data.append("S")
    return pe_se_data


rule all:
    input:
        # distribute init files
        expand(os.path.join(config["ROOTDIR"],"controls","init_files","{tissue_name}_{tag}.csv"), tissue_name=get_tissue_name(), tag=get_tag_data()),
        # dump_fastq
        expand(os.path.join(config["ROOTDIR"], "data", "{tissue_name}", "raw", "{tissue_name}_{tag}_{PE_SE}.fastq.gz"), zip, tissue_name=get_tissue_name(), tag=get_tag_data(), PE_SE=get_PE_SE_Data())


rule generate_genome:
    input:
        genome_fasta_file = config["STAR"]["GENERATE_GENOME"]["GENOME_FASTA_FILE"],
        gtf_file = config["STAR"]["GENERATE_GENOME"]["GTF_FILE"]
    output:
        genome_dir = directory(os.path.join(config["ROOTDIR"], config["STAR"]["GENERATE_GENOME"]["GENOME_DIR"])),
        rule_complete = touch(os.path.join(config["ROOTDIR"], "temp", "rule_complete", "generate_genome.complete"))
    threads: workflow.cores * 0.35
    params:
        run_mode = config["STAR"]["GENERATE_GENOME"]["RUN_MODE"],
        overhang = config["STAR"]["GENERATE_GENOME"]["OVERHANG"]
    shell:
        """
        module load star/2.7
        
        STAR \
        --runThreadN {threads} \
        --runMode {params.run_mode} \
        --genomeDir {output.genome_dir} \
        --genomeFastaFiles {input.genome_fasta_file} \
        --sjdbGTFfile {input.gtf_file} \
        --sjdbOverhang {params.overhang}
        """

rule distribute_init_files:
    input: config["MASTER_CONTROL"]
    output: temp(os.path.join(config["ROOTDIR"], "controls", "init_files", "{tissue_name}_{tag}.csv"))
    params:
        id = "{tissue_name}_{tag}"
    run:
        # Get lines in master control file
        # Open output for writing
        lines = open(str(input), "r").readlines()
        wfile = open(str(output), "w")
        for line in lines:

            # Only write line if the output file has the current tissue-name_tag (naiveB_S1R1) in the file name
            if params.id in line:
                    wfile.write(line)
        wfile.close()

rule prefetch_fastq:
    input: rules.distribute_init_files.output
    output:
        data = os.path.join(config["ROOTDIR"], "temp", "prefetch", "{tissue_name}_{tag}", "{srr_code}", "{srr_code}.sra")
    shell:
        """
        module load SRAtoolkit
        
        IFS=","
        while read srr name endtype; do
            prefetch $srr --output-file {output.data}
        done < {input}
        """

"""
Inputs and outputs are lists of equal length
Each input matches to one output, even if the inputs are the same
Example:
    input:
        results/temp/prefetch/naiveB_S1R1/SRR14231328/SRR14231328.sra   (Paired End)
        results/temp/prefetch/naiveB_S1R1/SRR14231328/SRR14231328.sra   (Paired End)
        
        results/temp/prefetch/naiveB_S3R1/SRR5110334/SRR5110334.sra     (Single End)
        
    output:
        results/data/naiveB/raw/naiveB_S1R1_1.fastq.gz                  (Paired End)
        results/data/naiveB/raw/naiveB_S1R1_2.fastq.gz                  (Paired End)
        
        results/data/naiveB/raw/naiveB_S3R1_S.fastq.gz                  (Single End)
"""
def generate_output_tuples(output_list: list[str]):
    """
    This function will generate a list of tuples that group like-files together
    Example:
        input:
            [
             "results/data/naiveB/raw/naiveB_S1R1_1.fastq.gz",
             "results/data/naiveB/raw/naiveB_S1R1_2.fastq.gz",

             "results/data/naiveB/raw/naiveB_S1R2.fastq.gz"
            ]

        output:
            [
                ("results/data/naiveB/raw/naiveB_S1R1_1.fastq.gz", "results/data/naiveB/raw/naiveB_S1R1_2.fastq.gz"),
                ("results/data/naiveB/raw/naiveB_S1R2.fastq.gz")
            ]

    :param output_list: A list of strings containing output file locations
    :return: A list of tuples containing grouped output file locations
    """

    new_list = []
    for i, output_file in enumerate(output_list):
        id = output_file.split("/")[-1].strip(".fastq.gz")
        try: # handle final index
            next_file = output_list[i+1]
            next_id = next_file.split("/")[-1].strip(".fastq.gz")
        except:
            if id.endswith("_1"): new_list.append(output_file)

        if id.endswith("_2"): # skip reverse reads if not accompanied by their forward
            continue
        elif next_id.endswith("_2") and id.endswith("_1"):
            new_list.append((output_file, output_list[i+1]))
        elif id.endswith("_1"):
            new_list.append(output_file)
        elif id.endswith("_S"):
            new_list.append(output_file)
        else:
            warnings.warn(f"{output_file} not handled!")

    return new_list

rule dump_fastq:
    input:
        data = expand(rules.prefetch_fastq.output.data, zip, tissue_name=get_tissue_name(), tag=get_tag_data(), srr_code=get_srr_data(), allow_missing=True)
    output:
        data = expand(os.path.join(config["ROOTDIR"], "data", "{tissue_name}", "raw", "{tissue_name}_{tag}_{PE_SE}.fastq.gz"), zip, tissue_name=get_tissue_name(), tag=get_tag_data(), PE_SE=get_PE_SE_Data(), allow_missing=True)
    threads: workflow.cores * 0.9  # max threads
    run:
        subprocess.run(["module", "load", "parallel-fastq-dump"])
        input_list = str(input).split(" ")
        output_list = str(output).split(" ")

        # Get unique items from list in the original order they were added
        input_index = np.unique(input_list, return_index=True)[1]
        input_list = [input_list[i] for i in sorted(input_index)]
        output_list = generate_output_tuples(output_list)

        # iterate through input and output items
        for i, (in_file, out_files) in enumerate(zip(input_list, output_list)):
            print(f"Working on file {in_file}")

            if type(out_files) is tuple:
                out_directory = os.path.dirname(out_files[0])
                subprocess.run(["parallel-fastq-dump", "--sra-id", f"{in_file}", "--threads", f"{threads}", "--outdir", f"{out_directory}", "--gzip", "--split-files"])

                fastq_dumped_files = os.listdir(out_directory)
                for j, (old_file, new_file) in enumerate(zip(fastq_dumped_files, out_files)):
                    old_file_path = os.path.join(out_directory, old_file)
                    os.rename(old_file_path, new_file)
            else:
                out_directory = os.path.dirname(out_files)
                subprocess.run(["parallel-fastq-dump", "--sra-id", f"{in_file}", "--threads", f"{threads}", "--outdir", f"{out_directory}", "--gzip"])

                fastq_dumped_files = os.listdir(out_directory)
                old_file_path = os.path.join(out_directory, fastq_dumped_files[0])
                os.rename(old_file_path, str(output))


"""
Trimming Plan
Have trim pull each file from rename_srr
Perform trimming on each file
"""
# if config["PERFORM_TRIM"]:
#     rule trim:
#                # os.path.join(config["ROOTDIR"], "data", "{tissue_name}", "raw_temp", "Bulk_{PE_SE}")
#         input: expand(rules.dump_fastq.output.data, tissue_name=get_tissue_name(), PE_SE=get_PE_SE_Data())
#         output: directory(os.path.join(config["ROOTDIR"], "data", "{tissue_name}", "trimmed_reads"))
#         shell: """
#             module load gnu-parallel # DOI https://doi.org/10.5281/zenodo.1146014
#             module load trim_galore  # trimGalore 10.5281/zenodo.5127898
#                                      # Cutadapt DOI:10.14806/ej.17.1.200
#
#             for file in {input}; do                         # path/to/file/naiveB_S1R1_1.fastq.gz
#                 fold="$(dirname $file)"                     # path/to/file/
#                 bfile="$(basename $file)"                   # naiveB_S1R1_1.fastq.gz
#                 bname=$(echo "bfile" | cut -f 1 -d '.')     # naiveB_S1R1_1
#                 tissue=$(echo "bfile" | cut -f 1 -d '_')    # naiveB
#                 tag=$(echo "bfile" | cut -f 2 -d '_')       # S1R1
#                 dir=$(echo "bfile" | cut -f 3 -d '_')       # 1
#                 if [ $dir -eq "2" ]; then   # skip over reverse reads completely
#                     continue
#                 elif [ -f "${{fold}}/{{tissue}}_{{tag}}_2.fastq.gz" ]; then    # if reverse read exists do paired trim
#                     trim_galore --paired -o {config[ROOTDIR]}/data/{{tissue}}/trimmed_reads/ \
#                         "${{fold}}/{{tissue}}_{{tag}}_1.fastq.gz" \
#                         "${{fold}}/{{tissue}}_{{tag}}_2.fastq.gz"
#                 else                                                        # single ended, no paired end argument
#                     trim_galore -o {config[ROOTDIR]}/data/{{tissue}}/trimmed_reads/ \
#                         "${{fold}}/{{tissue}}_{{tag}}_1.fastq.gz"
#                 fi
#             done
#             """

def collect_star_align_input(wildcards):
    if config["PERFORM_TRIM"]:
        return rules.trim.output
    else:
        return rules.dump_fastq.output.data
rule star_align:
    input: collect_star_align_input
    output: directory(os.path.join(config["ROOTDIR"],"data","{tissue_name}","aligned_reads"))
    threads: workflow.cores * 0.90
    shell:
        """
        STAR --runThreadN {threads} \
		--readFilesCommand {config[STAR][ALIGN_READS][READ_COMMAND]} \
		--readFilesIn $file1 $file2 \
		--genomeDir {config[STAR][GENERATE_GENOME][GENOME_DIR]} \
		--outFileNamePrefix {output} \
		--outSAMtype {config[STAR][ALIGN_READS][OUT_SAM_TYPE]} \
		--outSAMunmapped {config[STAR][ALIGN_READS][OUT_SAM_UNMAPPED} \
		--outSAMattributes {config[STAR][ALIGN_READS][OUT_SAM_ATTRIBUTES]} \
		--quantMode {config[STAR][ALIGN_READS][QUANT_MODE]}
        """

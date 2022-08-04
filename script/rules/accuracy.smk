# This file contains rules to test the accuracy of pangraph on simulated data.
# This is done by simulating the evolution of a population with horizontal transfer
# of genetic material, and comparing the real pangenome graph generated by the simulation
# to the pangenome graph reconstructed by pangraph using only the sequences.

import json

# extract config for accuracy rules
AC_config = config["accuracy"]

# list of different simulation parameters to be tested
with open(AC_config["sim-params"], "r") as f:
    AC_sim_params = json.load(f)
AC_hgt = AC_sim_params["hgt"]
AC_snps = AC_sim_params["snps"]
AC_snps_accplot = AC_sim_params["snps-accplot"]
# number of trials
AC_trials = list(range(1, AC_config["sim-ntrials"] + 1))

# alignemnt kernels options
AC_ker_opt = AC_config["kernel-options"]
AC_ker_names = list(AC_ker_opt.keys())


# rule to generate all the summary plots for the accuracy analaysis
rule AC_all:
    input:
        expand("figs/paper-accuracy-{kernel}.png", kernel=AC_ker_names),
        rules.AC_accuracy_comparison_plots.output,


# generate synthetic data for the accuracy analysis. This rule generates a pair of files.
# The json file contains the simulated pangenome graph and the fasta file the corresponding set of genomes.
rule AC_generate_data:
    message:
        "generating pangraph with hgt = {wildcards.hgt}, snps = {wildcards.snps}, n = {wildcards.n}"
    output:
        graph="synthetic_data/generated/{hgt}_{snps}/known_{n}.json",
        seqs="synthetic_data/generated/{hgt}_{snps}/seqs_{n}.fa",
    params:
        N=100,
        T=50,
        L=50000,
        ins=0.01,
    shell:
        """
        julia -t 1 --project=. workflow_scripts/make-sequence.jl \
            -N {params.N} -L {params.L} \
            | julia -t 1 --project=./.. ./../src/PanGraph.jl generate \
            -m {wildcards.snps} -r {wildcards.hgt} -t {params.T} -i {params.ins} \
            -o {output.graph} > {output.seqs}
        """


# Prioritize mmseq rule if the kernel is compatible. The rules are separated only
# so that when executing on the cluster we can allocate more resources for
# mmseqs execution.
ruleorder: AC_guess_pangraph_mmseqs > AC_guess_pangraph


# Reconstruct the pangenome graph with pangraph from synthetic sequences
rule AC_guess_pangraph:
    message:
        """
        reconstructing pangraph with kernel {wildcards.kernel}
        hgt = {wildcards.hgt}, snps = {wildcards.snps}, n = {wildcards.n}
        """
    input:
        rules.AC_generate_data.output.seqs,
    output:
        "synthetic_data/{kernel}/{hgt}_{snps}/guess_{n}.json",
    params:
        ker=lambda w: AC_ker_opt[w.kernel],
    shell:
        """
        julia -t 1 --project=./.. ./../src/PanGraph.jl build \
            --circular -a 0 -b 0 {params.ker} {input} > {output}
        """


# Same as previous rule, but specifically for mmseq kernel. This is done so that
# more resources can be allocated on cluster execution (cluster/cluster_config.json)
rule AC_guess_pangraph_mmseqs:
    message:
        """
        reconstructing pangraph with kernel mmseqs
        hgt = {wildcards.hgt}, snps = {wildcards.snps}, n = {wildcards.n}
        """
    input:
        rules.AC_generate_data.output.seqs,
    output:
        "synthetic_data/mmseqs/{hgt}_{snps}/guess_{n}.json",
    params:
        ker=AC_ker_opt["mmseqs"],
    conda:
        "../conda_envs/pangraph_build_env.yml"
    shell:
        """
        julia -t 8 --project=./.. ./../src/PanGraph.jl build \
            --circular -a 0 -b 0 {params.ker} {input} > {output}
        """


# Compares all the real and guessed pangraphs for a given value of the hgt and snps
# simulation parameters. Save the results in a jld2 julia file.
rule AC_single_accuracy:
    message:
        """
        generating partial accuracy database for:
        kernel = {wildcards.kernel} hgt = {wildcards.hgt}, snps = {wildcards.snps}
        """
    input:
        known=expand(
            "synthetic_data/generated/{{hgt}}_{{snps}}/known_{n}.json", n=AC_trials
        ),
        guess=expand(
            "synthetic_data/{{kernel}}/{{hgt}}_{{snps}}/guess_{n}.json", n=AC_trials
        ),
    output:
        temp("synthetic_data/{kernel}/{hgt}_{snps}/partial_accuracy.jld2"),
    shell:
        """
        julia -t 1 --project=. workflow_scripts/make-accuracy.jl {output} {input}
        """


# Collects the results of all the files generated by the previous rule in a single
# database, for all the tested hgt and snps conditions.
rule AC_accuracy_database:
    message:
        "generating accuracy database for kernel {wildcards.kernel}"
    input:
        expand(
            "synthetic_data/{{kernel}}/{hgt}_{snps}/partial_accuracy.jld2",
            hgt=AC_hgt,
            snps=AC_snps,
        ),
    output:
        "synthetic_data/results/accuracy-{kernel}.jld2",
    shell:
        """
        julia -t 1 --project=. workflow_scripts/concatenate-database.jl {output} {input}
        """


# For a given alignment kernel, generates different accuracy plots from the database
# generated by the previous rule.
rule AC_accuracy_plots:
    message:
        "generating accuracy plot for kernel {wildcards.kernel}"
    input:
        rules.AC_accuracy_database.output,
    output:
        "figs/cdf-accuracy-{kernel}.png",
        "figs/heatmap-accuracy-{kernel}.png",
        "figs/paper-accuracy-{kernel}.png",
        "figs/paper-accuracy-{kernel}.pdf",
    params:
        snps=AC_snps_accplot,
    shell:
        """
        julia -t 1 --project=. workflow_scripts/plot-accuracy.jl {input} figs {params.snps}
        """


# Generates plots to compare the accuracy of different alignment kernels.
rule AC_accuracy_comparison_plots:
    message:
        "generating accuracy comparison plots"
    input:
        expand("synthetic_data/results/accuracy-{kernel}.jld2", kernel=AC_ker_names),
    output:
        "figs/paper-accuracycomp.pdf",
        "figs/paper-accuracycomp-mutdens.pdf",
        "figs/paper-accuracycomp-scatter.pdf",
    shell:
        """
        julia -t 1 --project=. workflow_scripts/plot-accuracy-comparison.jl figs {input}
        """

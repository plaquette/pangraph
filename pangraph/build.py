"""
build a pangenome alignment from an annotated guide tree
"""
import os, sys
import builtins

from .utils import mkdir
from .tree import Tree

def open(path, *args, **kwargs):
    if path == '-':
        return sys.stdin
    return builtins.open(path, *args, **kwargs)

def register_args(parser):
    parser.add_argument("-d", "--dir",
                        metavar="directory",
                        type=str,
                        default=".",
                        help="directory used for output files")
    parser.add_argument("-l", "--len",
                        metavar="cutoff length",
                        type=int,
                        default=50,
                        help="minimum block size for nucleotides")
    parser.add_argument("input",
                        type=str,
                        default="-",
                        help="input guide tree [json]")

def main(args):
    '''
    Parameters
    ----------
    args : namespace
        arguments passed in via the command-line from pangraph
    Returns
    -------
    int
        returns 0 for success, 1 for general error
    '''
    with open(args.input, 'r') as input:
        T = Tree.from_json(input)

    root = args.dir.rstrip('/')
    tmp = f"{root}/tmp"
    mkdir(tmp)
    T.align(tmp, args.len)
    # TODO: when debugging phase is done, remove tmp directory

    # collect all non-trivial graphs, remove all intermediates
    graphs = T.collect()
    T.keep_only(graphs)

    for i, g in enumerate(graphs):
        with open(f"{root}/graph_{i:03d}.fa", 'w') as fd:
            g.write_fasta(fd)

    with open(f"{root}/pangraph.json", "w") as fd:
        T.write_json(fd, no_seqs=True)

    return 0

use crate::commands::marginalize::marginalize_args::PangraphMarginalizeArgs;
use crate::io::pangraph_json::PangraphJson;
use crate::utils::random::get_random_number_generator;
use eyre::Report;

pub fn marginalize_run(args: &PangraphMarginalizeArgs) -> Result<(), Report> {
  let PangraphMarginalizeArgs {
    input_aln,
    output_path,
    strains,
    seed,
  } = &args;

  let rng = get_random_number_generator(seed);

  let msa_json = PangraphJson::from_path(input_aln)?;

  Ok(())
}

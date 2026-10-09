# GROMACS 2026.4 with RAMD

This tree is the official **GROMACS 2026.4** source with the **Random
Acceleration Molecular Dynamics (RAMD)** feature ported from the
[gromacs-2024.1-ramd-2.1](https://github.com/HITS-MCM/gromacs-ramd) fork.

RAMD is a method to carry out molecular dynamics simulations with an additional
randomly oriented force applied to a molecule in the system, used to study
ligand dissociation pathways and residence times.

## What is in this tree

* `src/gromacs/ramd/` — the RAMD module: `gmx::RAMD` (an `IForceProvider`),
  the spherical random direction generator, and unit tests.
* `src/gromacs/mdtypes/ramd_params.h` — `gmx::RAMDParams` / `gmx::RAMDGroup`.
* `src/gromacs/gmxpreprocess/readramd.cpp` — reads the `ramd-*` mdp options and
  translates them into internal `pull-*` parameters.
* Small integration patches in `readir`, `grompp`, `tpxio`, `inputrec`,
  `sim_util`, `trajectory_writing`, `md`/`mimic`/`rerun`/`runner`,
  `legacymdrunoptions`, and the pulling module.
* `ramd-tests/` — CPU and GPU functional test suites (see below).
* `docs/user-guide/mdp-options.rst` — RAMD documentation.

## Limitations

1. **Legacy simulator only (`integrator = md`).**
   RAMD is a force provider registered in the legacy `do_md()` path.
   `integrator = md-vv` selects the modular simulator, where RAMD is not
   registered and therefore not applied. GPU update (`-update gpu`) is fine
   because in GROMACS 2026.4 it requires the `md` integrator, not `md-vv`.

2. **`.tpr` files are not compatible across RAMD versions.**
   The RAMD tpr is tagged `"RAMD"` and appends `tpxv_RAMD` to the tpx version
   enumeration, so tpr files written by `gromacs-2024.1-ramd` cannot be read by
   this build. Regenerate `.tpr` files with this build's `grompp`.

3. **GPU: PME on the GPU requires nonbonded on the GPU too.**
   GROMACS only allows PME offload together with GPU nonbonded
   (`-nb gpu -pme gpu`). `-nb cpu -pme gpu` is rejected. Very small systems
   (fewer than 900 atoms) are not offloaded to the GPU at all, so GPU tests
   must use a reasonably sized system.

4. **Multi-group RAMD** is supported through independent RAMD groups; see
   `ramd-ngroups` below.

See `03-已知限制-RAMD-2026.4.md` in the packaging directory for the detailed
analysis.

## Usage

RAMD is configured entirely through the `.mdp` file. Use the following options:

* `ramd`

  RAMD will be applied.

* `ramd-seed`

  Seed for the random direction generator.

* `ramd-eval-freq`

  This parameter affects the absolute dissociation time but has less effect on
  the relative dissociation times of different compounds. It is recommended to
  use the default value.

* `ramd-force-out-freq`

  This RAMD parameter resets `pull-nstxout` and `pull-nstfout`.

* `ramd-ngroups`

  The number of RAMD groups defining the ligand-receptor pair. Below only the
  options for group 1 are given; further groups simply increase the group index
  number.

* `ramd-group1-force`

  The force constant in kJ/mol/nm. Default value is 600 kJ/mol/nm. For a set of
  compounds with the dissociation rate expected to vary within the range of
  0.1-0.0001 1/s, a random force magnitude of 600 kJ/mol/nm can be applied. If
  necessary, the force magnitude can be adjusted according to the longest and
  shortest dissociation time observed in simulations. The upper threshold of
  the force magnitude is determined by the fast-dissociating compounds, whose
  dissociation time should be longer than 100 ps. The lower threshold of the
  force magnitude depends on the available computational facilities.

* `ramd-group1-r-min-dist`

  This parameter affects the absolute dissociation time but has less effect on
  the relative dissociation times of different compounds. It is recommended to
  use the default value.

* `ramd-group1-max-dist`

  This value has to be adjusted for the system studied: no protein-ligand
  contacts should be observed in the last snapshot of a dissociation
  trajectory. Usually 4 nm is enough, but in the case of a long dissociation
  channel (as in many membrane proteins) `max-dist` must be increased
  accordingly. Method performance is not very sensitive to the upper limit of
  this parameter since the motion of the free ligand due to the external force
  is very fast (i.e. the last part of the trajectory, where the ligand does not
  interact with the protein, usually has a negligible contribution to the
  observed dissociation time).

* `ramd-group1-receptor`

  Receptor for the first RAMD group. Default name is `Protein`.

* `ramd-group1-ligand`

  Ligand for the first RAMD group. Default name is `INH`.

* `ramd-group1-receptor-pbcatom`

  The value will be forwarded to the associated pull group of the receptor.
  Default value is 0, which takes the middle atom (by number).

* `ramd-group1-ligand-pbcatom`

  The value will be forwarded to the associated pull group of the ligand.
  Default value is 0, which takes the middle atom (by number).

* `ramd-pbc-ref-prev-step-com`

  The value will be forwarded to `pull-pbc-ref-prev-step-com`. Default value is
  `yes`.

* `ramd-connected-ligands`

  If `yes`, the trajectory will be terminated when all ligands have left the
  radius. If one ligand leaves the radius, its last assigned force will
  continue to be applied until the simulation ends or the ligand re-enters. If
  `no`, this reverts to standard RAMD for multiple disconnected ligands: each
  ligand is subject to a RAMD force until it has left the dissociation radius,
  and the simulation stops when all ligands have left the dissociation radius.
  Default value is `yes`.

### Running

```bash
gmx grompp -f ramd.mdp -c system.gro -p topol.top -n index.ndx -o ramd.tpr
gmx mdrun -deffnm ramd -ramd
```

The `-ramd` output file (ligand-receptor COM distance per RAMD group) is an
*optional* output file: it is only written when `-ramd` is given on the `mdrun`
command line (with or without an explicit filename). Use `integrator = md`.

## Test suites

```bash
cd ramd-tests
./setup.sh                 # optional: regenerate reference .tpr files
./run_ramd_tests.sh        # CPU functional tests
./run_ramd_gpu_tests.sh    # GPU functional tests
```

See `ramd-tests/README.md` for details.

The suites are also wired into CTest (`GMX_BUILD_RAMD_SHELL_TESTS=ON` by
default, `GMX_BUILD_RAMD_SHELL_GPU_TESTS=OFF`), so after building you can run:

```bash
ctest -R RamdShell        # RAMD shell suites
ctest -R "[Rr]amd"        # RAMD shell suites + C++ tests
```

---

The original RAMD README follows (from gromacs-2024.1-ramd-2.1).

[![Build Status](https://jenkins.h-its.org/buildStatus/icon?job=MCM/HITS-MCM/gromacs-ramd/main)](https://jenkins.h-its.org/job/MCM/job/HITS-MCM/job/gromacs-ramd/job/main/)

# Random Acceleration Molecular Dynamics (RAMD)

## Background

Random Acceleration Molecular Dynamics (RAMD) is a method to carry out
molecular dynamics simulations with an additional randomly oriented force
applied to a molecule in the system.

## Installation

See http://manual.gromacs.org/documentation/current/install-guide/index.html

## HPC deployment with EasyBuild

The [EasyBuild](http://easybuilders.github.io/easybuild/) recipe is available [here](https://github.com/BerndDoser/easybuild-easyconfigs/blob/hits/easybuild/easyconfigs/g/GROMACS/GROMACS-2020.5-RAMD-2.0-fosscuda-2019b.eb).

## Usage

Please use following mdp options:

 * ramd

   RAMD will be applied.

 * ramd-seed

   Seed for random direction generator

 * ramd-eval-freq

   This parameter affect absolute dissociation time but have less
   effect on the relative dissociation times of different compounds. It is
   recommended to use default value.

 * ramd-force-out-freq

   This ramd parameter resets pull-nstxout and pull-nstfout.

 * ramd-ngroups

   The number of ramd groups defining the ligand-receptor pair.
   Below only the pull options for group 1 are given,
   further groups simply increase the group index number.

 * ramd-group1-force

   The force constant in kJ/mol/nm. Default value is 600 kJ/mol/nm.
   For a set of compounds with the dissociation rate expected to vary
   within the range of 0.1-0.0001 1/s, a random force magnitude of 600
   kJ/mol/nm can be applied. If necessary, the force magnitude can be
   adjusted according to the longest and shortest dissociation time
   observed in simulations. The upper threshold of the force magnitude is
   determined by the fast-dissociated compounds, whose dissociation time
   should be longer than 100 ps. The lower threshold of the force magnitude
   depends on the computation facilities available.

 * ramd-group1-r-min-dist

   This parameter affect absolute dissociation time but have less
   effect on the relative dissociation times of different compounds. It is
   recommended to use default value.

 * ramd-group1-max-dist

   This value has to be adjusted for the system studied: no
   protein-ligand contacts should be observed in the last snapshot of a
   dissociation trajectory. Usually 4 nm is enough, but in the case
   of a long dissociation channel (as in many membrane proteins) maxDist must be
   increased accordingly. Method performance is not very sensitive to the
   upper limit of this parameter since motion of the free ligand due to the
   external force is very fast (i.e. the last part of the trajectory, where the
   ligand does not interact with the protein, usually has a negligible contribution
   to the observed dissociation time).

 * ramd-group1-receptor

   Receptor for the first RAMD group. Default name is 'Protein'.

 * ramd-group1-ligand

   Ligand for the first RAMD group. Default name is 'INH'.

 * ramd-group1-receptor-pbcatom

   The value will be forwarded to the associated pull group of the receptor.
   Default value is 0, which takes the middle atom (number wise).

 * ramd-group1-ligand-pbcatom

   The value will be forwarded to the associated pull group of the ligand.
   Default value is 0, which takes the middle atom (number wise).

 * ramd-pbc-ref-prev-step-com

   The value will be forwarded to pull-pbc-ref-prev-step-com. Default value is 'yes'.

 * ramd-connected-ligands

   If ‘yes’, the trajectory will be terminated when all ligands have left the radius.
   If one ligand leaves the radius, its last assigned force will continue to be
   applied until the simulation end or radius re-entry.
   If ‘no’, this should revert to standard RAMD for multiple disconnected ligands.
   Each ligand is subject to a RAMD force until the individual ligand has left the
   dissociation radius. The simulation stops when all ligands have left the
   dissociation radius. Default value is 'yes'.

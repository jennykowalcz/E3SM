module GapMortalityMod

  !-----------------------------------------------------------------------
  ! !DESCRIPTION:
  ! Module holding routines used in gap mortality for coupled carbon
  ! nitrogen code.
  ! add phosphorus fluxes - X.YANG
  !
  ! !USES:
  use shr_kind_mod        , only : r8 => shr_kind_r8
  use abortutils          , only : endrun
  use shr_log_mod         , only : errMsg => shr_log_errMsg
  use VegetationPropertiesType      , only : veg_vp
  use CNStateType         , only : cnstate_type
  use ColumnType          , only : col_pp
  use ColumnDataType      , only : col_cf, col_nf, col_pf
  use VegetationType      , only : veg_pp
  use VegetationDataType  , only : veg_cs, veg_cf, veg_ns, veg_nf
  use VegetationDataType  , only : veg_ps, veg_pf
  use CropType            , only : crop_type

  use elm_varctl          , only : nu_com
  use timeinfoMod , only : dayspyr_mod
  !
  implicit none
  save
  private

  !
  ! !PUBLIC MEMBER FUNCTIONS:
  public :: GapMortality
  public :: readGapMortParams

  type, public :: CNGapMortParamsType
      real(r8), pointer :: am     => null() ! mortality rate based on annual rate, fractional mortality (1/yr)
      real(r8), pointer :: k_mort => null() ! coeff. of growth efficiency in mortality equation
  end type CNGapMortParamsType

  type(CNGapMortParamsType),public ::  CNGapMortParamsInst

  !$acc declare create(cngapmortparamsinst)
  !-----------------------------------------------------------------------

contains

  !-----------------------------------------------------------------------
   subroutine readGapMortParams ( ncid )
      !
      ! !DESCRIPTION:
      ! Read in parameters
      !
      ! !USES:
      use ncdio_pio  , only : file_desc_t,ncd_io
      !
      ! !ARGUMENTS:
      implicit none
      type(file_desc_t),intent(inout) :: ncid   ! pio netCDF file id
      !
      ! !LOCAL VARIABLES:
      character(len=32)  :: subname = 'CNGapMortParamsType'
      character(len=100) :: errCode = '-Error reading in parameters file:'
      logical            :: readv ! has variable been read in or not
      real(r8)           :: tempr ! temporary to read in constant
      character(len=100) :: tString ! temp. var for reading
      !-----------------------------------------------------------------------
      allocate(CNGapMortParamsInst%am, CNGapMortParamsInst%k_mort)

      tString='r_mort'
      call ncd_io(varname=trim(tString),data=tempr, flag='read', ncid=ncid, readvar=readv)
      if ( .not. readv ) call endrun(msg=trim(errCode)//trim(tString)//errMsg(__FILE__, __LINE__))
      CNGapMortParamsInst%am=tempr

      tString='k_mort'
      call ncd_io(varname=trim(tString),data=tempr, flag='read', ncid=ncid, readvar=readv)
      if ( .not. readv ) call endrun(msg=trim(errCode)//trim(tString)//errMsg(__FILE__, __LINE__))
      CNGapMortParamsInst%k_mort=tempr

   end subroutine readGapMortParams

  !-----------------------------------------------------------------------
  subroutine GapMortality (num_soilc, filter_soilc, num_soilp, filter_soilp, &
       cnstate_vars, crop_vars )
    !
    ! !DESCRIPTION:
    ! Gap-phase mortality routine for coupled carbon-nitrogen code (CN)
    !
    ! !USES:
    !$acc routine seq
    use elm_varcon       , only: secspday
    use pftvarcon        , only: iscft
    use elm_varctl       , only: spinup_state, spinup_mortality_factor
    !
    ! !ARGUMENTS:
    integer                  , intent(in)    :: num_soilc       ! number of soil columns in filter
    integer                  , intent(in)    :: filter_soilc(:) ! column filter for soil points
    integer                  , intent(in)    :: num_soilp       ! number of soil patches in filter
    integer                  , intent(in)    :: filter_soilp(:) ! patch filter for soil points
    type(cnstate_type)       , intent(inout) :: cnstate_vars
    type(crop_type)          , intent(in)    :: crop_vars
    !
    ! !LOCAL VARIABLES:
    integer :: p             ! patch index
    integer :: fp            ! patch filter index
    real(r8):: am            ! rate for fractional mortality (1/yr)
    real(r8):: m             ! rate for fractional mortality (1/s)
    real(r8):: mort_max      ! asymptotic max mortality rate (/yr)
    real(r8):: k_mort = 0.3  ! coeff of growth efficiency in mortality equation
    real(r8):: dayspyr
    !-----------------------------------------------------------------------

    associate(                                                       &
         ivt                                 =>    veg_pp%itype    , & ! Input:  [integer  (:) ]  pft vegetation type
         croplive                            =>    crop_vars%croplive_patch & ! Input:  [logical  (:)   ]  flag, true if planted, not harvested
         )

      dayspyr = dayspyr_mod
      ! set the mortality rate based on annual rate
      am = CNGapMortParamsInst%am
      ! set coeff of growth efficiency in mortality equation
      k_mort = CNGapMortParamsInst%k_mort

      if (nu_com .eq. 'RD') then
          call mortality_rate_soilorder(num_soilp,filter_soilp,cnstate_vars)
      end if


      ! patch loop
      do fp = 1,num_soilp
         p = filter_soilp(fp)

         if (nu_com .eq. 'RD') then
             am = cnstate_vars%r_mort_cal_patch(p)
         end if


        m  = am/(dayspyr * secspday)

         !------------------------------------------------------
         ! patch-level gap mortality carbon fluxes
         !------------------------------------------------------

         ! displayed pools
           veg_cf%m_leafc_to_litter(p)     = 0._r8 
           veg_cf%m_livestemc_to_litter(p) = 0._r8 
         if((.not. iscft(ivt(p))) .or. (iscft(ivt(p)) .and. croplive(p))) then
           veg_cf%m_leafc_to_litter(p)               = veg_cs%leafc(p)               * m
           veg_cf%m_livestemc_to_litter(p)           = veg_cs%livestemc(p)           * m
         end if
         veg_cf%m_frootc_to_litter(p)              = veg_cs%frootc(p)              * m
         veg_cf%m_deadstemc_to_litter(p)           = veg_cs%deadstemc(p)           * m
         veg_cf%m_livecrootc_to_litter(p)          = veg_cs%livecrootc(p)          * m
         veg_cf%m_deadcrootc_to_litter(p)          = veg_cs%deadcrootc(p)          * m
         if (spinup_state >= 1) then
           veg_cf%m_deadstemc_to_litter(p)         = veg_cs%deadstemc(p)*m * spinup_mortality_factor
           veg_cf%m_deadcrootc_to_litter(p)        = veg_cs%deadcrootc(p)*m * spinup_mortality_factor
         end if

         ! storage pools
         veg_cf%m_leafc_storage_to_litter(p)       = veg_cs%leafc_storage(p)       * m
         veg_cf%m_frootc_storage_to_litter(p)      = veg_cs%frootc_storage(p)      * m
         veg_cf%m_livestemc_storage_to_litter(p)   = veg_cs%livestemc_storage(p)   * m
         veg_cf%m_deadstemc_storage_to_litter(p)   = veg_cs%deadstemc_storage(p)   * m
         veg_cf%m_livecrootc_storage_to_litter(p)  = veg_cs%livecrootc_storage(p)  * m
         veg_cf%m_deadcrootc_storage_to_litter(p)  = veg_cs%deadcrootc_storage(p)  * m
         veg_cf%m_gresp_storage_to_litter(p)       = veg_cs%gresp_storage(p)       * m
         veg_cf%m_cpool_to_litter(p)               = veg_cs%cpool(p)               * m

         ! transfer pools
         veg_cf%m_leafc_xfer_to_litter(p)          = veg_cs%leafc_xfer(p)          * m
         veg_cf%m_frootc_xfer_to_litter(p)         = veg_cs%frootc_xfer(p)         * m
         veg_cf%m_livestemc_xfer_to_litter(p)      = veg_cs%livestemc_xfer(p)      * m
         veg_cf%m_deadstemc_xfer_to_litter(p)      = veg_cs%deadstemc_xfer(p)      * m
         veg_cf%m_livecrootc_xfer_to_litter(p)     = veg_cs%livecrootc_xfer(p)     * m
         veg_cf%m_deadcrootc_xfer_to_litter(p)     = veg_cs%deadcrootc_xfer(p)     * m
         veg_cf%m_gresp_xfer_to_litter(p)          = veg_cs%gresp_xfer(p)          * m

         !------------------------------------------------------
         ! patch-level gap mortality nitrogen fluxes
         !------------------------------------------------------

         ! displayed pools
         veg_nf%m_leafn_to_litter(p) = 0._r8 
         veg_nf%m_livestemn_to_litter(p) = 0._r8 
         if((.not. iscft(ivt(p))) .or. (iscft(ivt(p)) .and. croplive(p))) then
           veg_nf%m_leafn_to_litter(p)               = veg_ns%leafn(p)               * m
           veg_nf%m_livestemn_to_litter(p)           = veg_ns%livestemn(p)           * m
         end if
         veg_nf%m_frootn_to_litter(p)              = veg_ns%frootn(p)              * m
         veg_nf%m_deadstemn_to_litter(p)           = veg_ns%deadstemn(p)           * m
         veg_nf%m_livecrootn_to_litter(p)          = veg_ns%livecrootn(p)          * m
         veg_nf%m_deadcrootn_to_litter(p)          = veg_ns%deadcrootn(p)          * m
         veg_nf%m_retransn_to_litter(p) = 0._r8
         if (.not. iscft(ivt(p))) then
            veg_nf%m_retransn_to_litter(p) = veg_ns%retransn(p) * m
         end if
         veg_nf%m_npool_to_litter(p)               = veg_ns%npool(p)               * m

         if (spinup_state >= 1) then
           veg_nf%m_deadstemn_to_litter(p)         = veg_ns%deadstemn(p)  * m &
                * spinup_mortality_factor
           veg_nf%m_deadcrootn_to_litter(p)        = veg_ns%deadcrootn(p) * m &
                * spinup_mortality_factor
         end if

         ! storage pools
         veg_nf%m_leafn_storage_to_litter(p)       = veg_ns%leafn_storage(p)       * m
         veg_nf%m_frootn_storage_to_litter(p)      = veg_ns%frootn_storage(p)      * m
         veg_nf%m_livestemn_storage_to_litter(p)   = veg_ns%livestemn_storage(p)   * m
         veg_nf%m_deadstemn_storage_to_litter(p)   = veg_ns%deadstemn_storage(p)   * m
         veg_nf%m_livecrootn_storage_to_litter(p)  = veg_ns%livecrootn_storage(p)  * m
         veg_nf%m_deadcrootn_storage_to_litter(p)  = veg_ns%deadcrootn_storage(p)  * m

         ! transfer pools
         veg_nf%m_leafn_xfer_to_litter(p)          = veg_ns%leafn_xfer(p)          * m
         veg_nf%m_frootn_xfer_to_litter(p)         = veg_ns%frootn_xfer(p)         * m
         veg_nf%m_livestemn_xfer_to_litter(p)      = veg_ns%livestemn_xfer(p)      * m
         veg_nf%m_deadstemn_xfer_to_litter(p)      = veg_ns%deadstemn_xfer(p)      * m
         veg_nf%m_livecrootn_xfer_to_litter(p)     = veg_ns%livecrootn_xfer(p)     * m
         veg_nf%m_deadcrootn_xfer_to_litter(p)     = veg_ns%deadcrootn_xfer(p)     * m

         !------------------------------------------------------
         ! patch-level gap mortality phosphorus fluxes
         !------------------------------------------------------

         ! displayed pools
         veg_pf%m_leafp_to_litter(p)     = 0._r8 
         veg_pf%m_livestemp_to_litter(p) = 0._r8 
         if((.not. iscft(ivt(p))) .or. (iscft(ivt(p)) .and. croplive(p))) then
           veg_pf%m_leafp_to_litter(p)               = veg_ps%leafp(p)               * m
           veg_pf%m_livestemp_to_litter(p)           = veg_ps%livestemp(p)           * m
         endif
         veg_pf%m_frootp_to_litter(p)              = veg_ps%frootp(p)              * m
         veg_pf%m_deadstemp_to_litter(p)           = veg_ps%deadstemp(p)           * m
         veg_pf%m_livecrootp_to_litter(p)          = veg_ps%livecrootp(p)          * m
         veg_pf%m_deadcrootp_to_litter(p)          = veg_ps%deadcrootp(p)          * m
         
         veg_pf%m_retransp_to_litter(p)            = 0._r8 
         if (.not. iscft(ivt(p))) then
            veg_pf%m_retransp_to_litter(p) = veg_ps%retransp(p) * m
         end if
         veg_pf%m_ppool_to_litter(p)               = veg_ps%ppool(p)               * m

         if (spinup_state >= 1) then
           veg_pf%m_deadstemp_to_litter(p)         = veg_ps%deadstemp(p)  * m &
                * spinup_mortality_factor
           veg_pf%m_deadcrootp_to_litter(p)        = veg_ps%deadcrootp(p) * m &
                * spinup_mortality_factor
         end if

         ! storage pools
         veg_pf%m_leafp_storage_to_litter(p)       = veg_ps%leafp_storage(p)       * m
         veg_pf%m_frootp_storage_to_litter(p)      = veg_ps%frootp_storage(p)      * m
         veg_pf%m_livestemp_storage_to_litter(p)   = veg_ps%livestemp_storage(p)   * m
         veg_pf%m_deadstemp_storage_to_litter(p)   = veg_ps%deadstemp_storage(p)   * m
         veg_pf%m_livecrootp_storage_to_litter(p)  = veg_ps%livecrootp_storage(p)  * m
         veg_pf%m_deadcrootp_storage_to_litter(p)  = veg_ps%deadcrootp_storage(p)  * m

         ! transfer pools
         veg_pf%m_leafp_xfer_to_litter(p)          = veg_ps%leafp_xfer(p)          * m
         veg_pf%m_frootp_xfer_to_litter(p)         = veg_ps%frootp_xfer(p)         * m
         veg_pf%m_livestemp_xfer_to_litter(p)      = veg_ps%livestemp_xfer(p)      * m
         veg_pf%m_deadstemp_xfer_to_litter(p)      = veg_ps%deadstemp_xfer(p)      * m
         veg_pf%m_livecrootp_xfer_to_litter(p)     = veg_ps%livecrootp_xfer(p)     * m
         veg_pf%m_deadcrootp_xfer_to_litter(p)     = veg_ps%deadcrootp_xfer(p)     * m

      end do ! end of pft loop

      ! gather all pft-level litterfall fluxes to the column
      ! for litter C and N inputs

      call CNGapPftToColumn(num_soilc, filter_soilc, &
           cnstate_vars)

    end associate
  end subroutine GapMortality

  !-----------------------------------------------------------------------
  subroutine CNGapPftToColumn ( &
       num_soilc, filter_soilc, &
       cnstate_vars)
    !$acc routine seq
    ! !DESCRIPTION:
    ! called in the middle of CNGapMoratlity to gather all pft-level gap mortality fluxes
    ! to the column level and assign them to the three litter pools
    !
    ! !USES:
    use elm_varpar , only : maxpatch_pft, nlevdecomp
    !
    ! !ARGUMENTS:
    integer                 , intent(in)    :: num_soilc       ! number of soil columns in filter
    integer                 , intent(in)    :: filter_soilc(:) ! soil column filter
    type(cnstate_type)      , intent(in)    :: cnstate_vars
    !
    ! !LOCAL VARIABLES:
    integer :: fc,c,pi,p,j               ! indices
    !-----------------------------------------------------------------------

    associate(                                                                              &
         ivt                                 =>    veg_pp%itype                            , & ! Input:  [integer  (:)   ]  pft vegetation type
         wtcol                               =>    veg_pp%wtcol                            , & ! Input:  [real(r8) (:)   ]  pft weight relative to column (0-1)

         lf_flab                             =>    veg_vp%lf_flab                          , & ! Input:  [real(r8) (:)   ]  leaf litter labile fraction
         lf_fcel                             =>    veg_vp%lf_fcel                          , & ! Input:  [real(r8) (:)   ]  leaf litter cellulose fraction
         lf_flig                             =>    veg_vp%lf_flig                          , & ! Input:  [real(r8) (:)   ]  leaf litter lignin fraction
         fr_flab                             =>    veg_vp%fr_flab                          , & ! Input:  [real(r8) (:)   ]  fine root litter labile fraction
         fr_fcel                             =>    veg_vp%fr_fcel                          , & ! Input:  [real(r8) (:)   ]  fine root litter cellulose fraction
         fr_flig                             =>    veg_vp%fr_flig                          , & ! Input:  [real(r8) (:)   ]  fine root litter lignin fraction

         leaf_prof                           =>    cnstate_vars%leaf_prof_patch            , & ! Input:  [real(r8) (:,:) ]  (1/m) profile of leaves
         froot_prof                          =>    cnstate_vars%froot_prof_patch           , & ! Input:  [real(r8) (:,:) ]  (1/m) profile of fine roots
         croot_prof                          =>    cnstate_vars%croot_prof_patch           , & ! Input:  [real(r8) (:,:) ]  (1/m) profile of coarse roots
         stem_prof                           =>    cnstate_vars%stem_prof_patch            , & ! Input:  [real(r8) (:,:) ]  (1/m) profile of stems

         m_leafc_to_litter                   =>    veg_cf%m_leafc_to_litter                , & ! Input:  [real(r8) (:)   ]
         m_frootc_to_litter                  =>    veg_cf%m_frootc_to_litter               , & ! Input:  [real(r8) (:)   ]
         m_livestemc_to_litter               =>    veg_cf%m_livestemc_to_litter            , & ! Input:  [real(r8) (:)   ]
         m_deadstemc_to_litter               =>    veg_cf%m_deadstemc_to_litter            , & ! Input:  [real(r8) (:)   ]
         m_livecrootc_to_litter              =>    veg_cf%m_livecrootc_to_litter           , & ! Input:  [real(r8) (:)   ]
         m_deadcrootc_to_litter              =>    veg_cf%m_deadcrootc_to_litter           , & ! Input:  [real(r8) (:)   ]
         m_leafc_storage_to_litter           =>    veg_cf%m_leafc_storage_to_litter        , & ! Input:  [real(r8) (:)   ]
         m_frootc_storage_to_litter          =>    veg_cf%m_frootc_storage_to_litter       , & ! Input:  [real(r8) (:)   ]
         m_livestemc_storage_to_litter       =>    veg_cf%m_livestemc_storage_to_litter    , & ! Input:  [real(r8) (:)   ]
         m_deadstemc_storage_to_litter       =>    veg_cf%m_deadstemc_storage_to_litter    , & ! Input:  [real(r8) (:)   ]
         m_livecrootc_storage_to_litter      =>    veg_cf%m_livecrootc_storage_to_litter   , & ! Input:  [real(r8) (:)   ]
         m_deadcrootc_storage_to_litter      =>    veg_cf%m_deadcrootc_storage_to_litter   , & ! Input:  [real(r8) (:)   ]
         m_gresp_storage_to_litter           =>    veg_cf%m_gresp_storage_to_litter        , & ! Input:  [real(r8) (:)   ]
         m_leafc_xfer_to_litter              =>    veg_cf%m_leafc_xfer_to_litter           , & ! Input:  [real(r8) (:)   ]
         m_frootc_xfer_to_litter             =>    veg_cf%m_frootc_xfer_to_litter          , & ! Input:  [real(r8) (:)   ]
         m_livestemc_xfer_to_litter          =>    veg_cf%m_livestemc_xfer_to_litter       , & ! Input:  [real(r8) (:)   ]
         m_deadstemc_xfer_to_litter          =>    veg_cf%m_deadstemc_xfer_to_litter       , & ! Input:  [real(r8) (:)   ]
         m_livecrootc_xfer_to_litter         =>    veg_cf%m_livecrootc_xfer_to_litter      , & ! Input:  [real(r8) (:)   ]
         m_deadcrootc_xfer_to_litter         =>    veg_cf%m_deadcrootc_xfer_to_litter      , & ! Input:  [real(r8) (:)   ]
         m_gresp_xfer_to_litter              =>    veg_cf%m_gresp_xfer_to_litter           , & ! Input:  [real(r8) (:)   ]
         m_cpool_to_litter                   =>    veg_cf%m_cpool_to_litter                , & ! Input:  [real(r8) (:)   ]

         m_leafn_to_litter                   =>    veg_nf%m_leafn_to_litter              , & ! Input:  [real(r8) (:)   ]
         m_frootn_to_litter                  =>    veg_nf%m_frootn_to_litter             , & ! Input:  [real(r8) (:)   ]
         m_livestemn_to_litter               =>    veg_nf%m_livestemn_to_litter          , & ! Input:  [real(r8) (:)   ]
         m_deadstemn_to_litter               =>    veg_nf%m_deadstemn_to_litter          , & ! Input:  [real(r8) (:)   ]
         m_livecrootn_to_litter              =>    veg_nf%m_livecrootn_to_litter         , & ! Input:  [real(r8) (:)   ]
         m_deadcrootn_to_litter              =>    veg_nf%m_deadcrootn_to_litter         , & ! Input:  [real(r8) (:)   ]
         m_retransn_to_litter                =>    veg_nf%m_retransn_to_litter           , & ! Input:  [real(r8) (:)   ]
         m_npool_to_litter                   =>    veg_nf%m_npool_to_litter              , & ! Input:  [real(r8) (:)   ]
         m_leafn_storage_to_litter           =>    veg_nf%m_leafn_storage_to_litter      , & ! Input:  [real(r8) (:)   ]
         m_frootn_storage_to_litter          =>    veg_nf%m_frootn_storage_to_litter     , & ! Input:  [real(r8) (:)   ]
         m_livestemn_storage_to_litter       =>    veg_nf%m_livestemn_storage_to_litter  , & ! Input:  [real(r8) (:)   ]
         m_deadstemn_storage_to_litter       =>    veg_nf%m_deadstemn_storage_to_litter  , & ! Input:  [real(r8) (:)   ]
         m_livecrootn_storage_to_litter      =>    veg_nf%m_livecrootn_storage_to_litter , & ! Input:  [real(r8) (:)   ]
         m_deadcrootn_storage_to_litter      =>    veg_nf%m_deadcrootn_storage_to_litter , & ! Input:  [real(r8) (:)   ]
         m_leafn_xfer_to_litter              =>    veg_nf%m_leafn_xfer_to_litter         , & ! Input:  [real(r8) (:)   ]
         m_frootn_xfer_to_litter             =>    veg_nf%m_frootn_xfer_to_litter        , & ! Input:  [real(r8) (:)   ]
         m_livestemn_xfer_to_litter          =>    veg_nf%m_livestemn_xfer_to_litter     , & ! Input:  [real(r8) (:)   ]
         m_deadstemn_xfer_to_litter          =>    veg_nf%m_deadstemn_xfer_to_litter     , & ! Input:  [real(r8) (:)   ]
         m_livecrootn_xfer_to_litter         =>    veg_nf%m_livecrootn_xfer_to_litter    , & ! Input:  [real(r8) (:)   ]
         m_deadcrootn_xfer_to_litter         =>    veg_nf%m_deadcrootn_xfer_to_litter    , & ! Input:  [real(r8) (:)   ]

         !! add phosphorus  -X.YANG
         m_leafp_to_litter                   =>    veg_pf%m_leafp_to_litter              , & ! Input:  [real(r8) (:)   ]
         m_frootp_to_litter                  =>    veg_pf%m_frootp_to_litter             , & ! Input:  [real(r8) (:)   ]
         m_livestemp_to_litter               =>    veg_pf%m_livestemp_to_litter          , & ! Input:  [real(r8) (:)   ]
         m_deadstemp_to_litter               =>    veg_pf%m_deadstemp_to_litter          , & ! Input:  [real(r8) (:)   ]
         m_livecrootp_to_litter              =>    veg_pf%m_livecrootp_to_litter         , & ! Input:  [real(r8) (:)   ]
         m_deadcrootp_to_litter              =>    veg_pf%m_deadcrootp_to_litter         , & ! Input:  [real(r8) (:)   ]
         m_retransp_to_litter                =>    veg_pf%m_retransp_to_litter           , & ! Input:  [real(r8) (:)   ]
         m_ppool_to_litter                   =>    veg_pf%m_ppool_to_litter              , & ! Input:  [real(r8) (:)   ]
         m_leafp_storage_to_litter           =>    veg_pf%m_leafp_storage_to_litter      , & ! Input:  [real(r8) (:)   ]
         m_frootp_storage_to_litter          =>    veg_pf%m_frootp_storage_to_litter     , & ! Input:  [real(r8) (:)   ]
         m_livestemp_storage_to_litter       =>    veg_pf%m_livestemp_storage_to_litter  , & ! Input:  [real(r8) (:)   ]
         m_deadstemp_storage_to_litter       =>    veg_pf%m_deadstemp_storage_to_litter  , & ! Input:  [real(r8) (:)   ]
         m_livecrootp_storage_to_litter      =>    veg_pf%m_livecrootp_storage_to_litter , & ! Input:  [real(r8) (:)   ]
         m_deadcrootp_storage_to_litter      =>    veg_pf%m_deadcrootp_storage_to_litter , & ! Input:  [real(r8) (:)   ]
         m_leafp_xfer_to_litter              =>    veg_pf%m_leafp_xfer_to_litter         , & ! Input:  [real(r8) (:)   ]
         m_frootp_xfer_to_litter             =>    veg_pf%m_frootp_xfer_to_litter        , & ! Input:  [real(r8) (:)   ]
         m_livestemp_xfer_to_litter          =>    veg_pf%m_livestemp_xfer_to_litter     , & ! Input:  [real(r8) (:)   ]
         m_deadstemp_xfer_to_litter          =>    veg_pf%m_deadstemp_xfer_to_litter     , & ! Input:  [real(r8) (:)   ]
         m_livecrootp_xfer_to_litter         =>    veg_pf%m_livecrootp_xfer_to_litter    , & ! Input:  [real(r8) (:)   ]
         m_deadcrootp_xfer_to_litter         =>    veg_pf%m_deadcrootp_xfer_to_litter    , & ! Input:  [real(r8) (:)   ]

         gap_mortality_c_to_litr_met_c       =>    col_cf%gap_mortality_c_to_litr_met_c      , & ! InOut:  [real(r8) (:,:) ]  C fluxes associated with gap mortality to litter metabolic pool (gC/m3/s)
         gap_mortality_c_to_litr_cel_c       =>    col_cf%gap_mortality_c_to_litr_cel_c      , & ! InOut:  [real(r8) (:,:) ]  C fluxes associated with gap mortality to litter cellulose pool (gC/m3/s)
         gap_mortality_c_to_litr_lig_c       =>    col_cf%gap_mortality_c_to_litr_lig_c      , & ! InOut:  [real(r8) (:,:) ]  C fluxes associated with gap mortality to litter lignin pool (gC/m3/s)
         gap_mortality_c_to_cwdc             =>    col_cf%gap_mortality_c_to_cwdc            , & ! InOut:  [real(r8) (:,:) ]  C fluxes associated with gap mortality to CWD pool (gC/m3/s)

         gap_mortality_n_to_litr_met_n       =>    col_nf%gap_mortality_n_to_litr_met_n    , & ! InOut:  [real(r8) (:,:) ]  N fluxes associated with gap mortality to litter metabolic pool (gN/m3/s)
         gap_mortality_n_to_litr_cel_n       =>    col_nf%gap_mortality_n_to_litr_cel_n    , & ! InOut:  [real(r8) (:,:) ]  N fluxes associated with gap mortality to litter cellulose pool (gN/m3/s)
         gap_mortality_n_to_litr_lig_n       =>    col_nf%gap_mortality_n_to_litr_lig_n    , & ! InOut:  [real(r8) (:,:) ]  N fluxes associated with gap mortality to litter lignin pool (gN/m3/s)
         gap_mortality_n_to_cwdn             =>    col_nf%gap_mortality_n_to_cwdn          ,  & ! InOut:  [real(r8) (:,:) ]  N fluxes associated with gap mortality to CWD pool (gN/m3/s)

         gap_mortality_p_to_litr_met_p       =>    col_pf%gap_mortality_p_to_litr_met_p    , & ! InOut:  [real(r8) (:,:) ]  N fluxes associated with gap mortality to litter metabolic pool (gN/m3/s)
         gap_mortality_p_to_litr_cel_p       =>    col_pf%gap_mortality_p_to_litr_cel_p    , & ! InOut:  [real(r8) (:,:) ]  N fluxes associated with gap mortality to litter cellulose pool (gN/m3/s)
         gap_mortality_p_to_litr_lig_p       =>    col_pf%gap_mortality_p_to_litr_lig_p    , & ! InOut:  [real(r8) (:,:) ]  N fluxes associated with gap mortality to litter lignin pool (gN/m3/s)
         gap_mortality_p_to_cwdp             =>    col_pf%gap_mortality_p_to_cwdp            & ! InOut:  [real(r8) (:,:) ]  N fluxes associated with gap mortality to CWD pool (gN/m3/s)

         )

      do j = 1,nlevdecomp
         do pi = 1,maxpatch_pft
            do fc = 1,num_soilc
               c = filter_soilc(fc)

               if (pi <=  col_pp%npfts(c)) then
                  p = col_pp%pfti(c) + pi - 1

                  if (veg_pp%active(p)) then

                     ! leaf gap mortality carbon fluxes
                     gap_mortality_c_to_litr_met_c(c,j) = gap_mortality_c_to_litr_met_c(c,j) + &
                          m_leafc_to_litter(p) * lf_flab(ivt(p)) * wtcol(p) * leaf_prof(p,j)
                     gap_mortality_c_to_litr_cel_c(c,j) = gap_mortality_c_to_litr_cel_c(c,j) + &
                          m_leafc_to_litter(p) * lf_fcel(ivt(p)) * wtcol(p) * leaf_prof(p,j)
                     gap_mortality_c_to_litr_lig_c(c,j) = gap_mortality_c_to_litr_lig_c(c,j) + &
                          m_leafc_to_litter(p) * lf_flig(ivt(p)) * wtcol(p) * leaf_prof(p,j)

                     ! fine root gap mortality carbon fluxes
                     gap_mortality_c_to_litr_met_c(c,j) = gap_mortality_c_to_litr_met_c(c,j) + &
                          m_frootc_to_litter(p) * fr_flab(ivt(p)) * wtcol(p) * froot_prof(p,j)
                     gap_mortality_c_to_litr_cel_c(c,j) = gap_mortality_c_to_litr_cel_c(c,j) + &
                          m_frootc_to_litter(p) * fr_fcel(ivt(p)) * wtcol(p) * froot_prof(p,j)
                     gap_mortality_c_to_litr_lig_c(c,j) = gap_mortality_c_to_litr_lig_c(c,j) + &
                          m_frootc_to_litter(p) * fr_flig(ivt(p)) * wtcol(p) * froot_prof(p,j)

                     ! wood gap mortality carbon fluxes
                     gap_mortality_c_to_cwdc(c,j)  = gap_mortality_c_to_cwdc(c,j)  + &
                          (m_livestemc_to_litter(p) + m_deadstemc_to_litter(p))  * wtcol(p) * stem_prof(p,j)
                     gap_mortality_c_to_cwdc(c,j) = gap_mortality_c_to_cwdc(c,j) + &
                          (m_livecrootc_to_litter(p) + m_deadcrootc_to_litter(p)) * wtcol(p) * croot_prof(p,j)
                     ! storage gap mortality carbon fluxes
                     gap_mortality_c_to_litr_met_c(c,j)      = gap_mortality_c_to_litr_met_c(c,j)      + &
                          (m_cpool_to_litter(p) + m_leafc_storage_to_litter(p) + m_gresp_storage_to_litter(p)) * wtcol(p)&
                          * leaf_prof(p,j)
                     gap_mortality_c_to_litr_met_c(c,j)     = gap_mortality_c_to_litr_met_c(c,j)     + &
                          m_frootc_storage_to_litter(p)     * wtcol(p) * froot_prof(p,j)
                     gap_mortality_c_to_litr_met_c(c,j)  = gap_mortality_c_to_litr_met_c(c,j)  + &
                          (m_livestemc_storage_to_litter(p) + m_deadstemc_storage_to_litter(p))  * wtcol(p) * stem_prof(p,j)
                     gap_mortality_c_to_litr_met_c(c,j) = gap_mortality_c_to_litr_met_c(c,j) + &
                          (m_livecrootc_storage_to_litter(p) + m_deadcrootc_storage_to_litter(p)) * wtcol(p) * croot_prof(p,j)

                     ! transfer gap mortality carbon fluxes
                     gap_mortality_c_to_litr_met_c(c,j)      = gap_mortality_c_to_litr_met_c(c,j)      + &
                          (m_leafc_xfer_to_litter(p) + m_gresp_xfer_to_litter(p))     * wtcol(p) * leaf_prof(p,j)
                     gap_mortality_c_to_litr_met_c(c,j)     = gap_mortality_c_to_litr_met_c(c,j)     + &
                          m_frootc_xfer_to_litter(p)     * wtcol(p) * froot_prof(p,j)
                     gap_mortality_c_to_litr_met_c(c,j)  = gap_mortality_c_to_litr_met_c(c,j)  + &
                          (m_livestemc_xfer_to_litter(p) + m_deadstemc_xfer_to_litter(p))  * wtcol(p) * stem_prof(p,j)
                     gap_mortality_c_to_litr_met_c(c,j) = gap_mortality_c_to_litr_met_c(c,j) + &
                          (m_livecrootc_xfer_to_litter(p) + m_deadcrootc_xfer_to_litter(p)) * wtcol(p) * croot_prof(p,j)

                     ! leaf gap mortality nitrogen fluxes
                     gap_mortality_n_to_litr_met_n(c,j) = gap_mortality_n_to_litr_met_n(c,j) + &
                          m_leafn_to_litter(p) * lf_flab(ivt(p)) * wtcol(p) * leaf_prof(p,j)
                     gap_mortality_n_to_litr_cel_n(c,j) = gap_mortality_n_to_litr_cel_n(c,j) + &
                          m_leafn_to_litter(p) * lf_fcel(ivt(p)) * wtcol(p) * leaf_prof(p,j)
                     gap_mortality_n_to_litr_lig_n(c,j) = gap_mortality_n_to_litr_lig_n(c,j) + &
                          m_leafn_to_litter(p) * lf_flig(ivt(p)) * wtcol(p) * leaf_prof(p,j)

                     ! fine root litter nitrogen fluxes
                     gap_mortality_n_to_litr_met_n(c,j) = gap_mortality_n_to_litr_met_n(c,j) + &
                          m_frootn_to_litter(p) * fr_flab(ivt(p)) * wtcol(p) * froot_prof(p,j)
                     gap_mortality_n_to_litr_cel_n(c,j) = gap_mortality_n_to_litr_cel_n(c,j) + &
                          m_frootn_to_litter(p) * fr_fcel(ivt(p)) * wtcol(p) * froot_prof(p,j)
                     gap_mortality_n_to_litr_lig_n(c,j) = gap_mortality_n_to_litr_lig_n(c,j) + &
                          m_frootn_to_litter(p) * fr_flig(ivt(p)) * wtcol(p) * froot_prof(p,j)

                     ! wood gap mortality nitrogen fluxes
                     gap_mortality_n_to_cwdn(c,j)  = gap_mortality_n_to_cwdn(c,j)  + &
                          (m_livestemn_to_litter(p) + m_deadstemn_to_litter(p))  * wtcol(p) * stem_prof(p,j)
                     gap_mortality_n_to_cwdn(c,j) = gap_mortality_n_to_cwdn(c,j) + &
                          (m_livecrootn_to_litter(p) + m_deadcrootn_to_litter(p)) * wtcol(p) * croot_prof(p,j)

                     ! retranslocated N pool gap mortality fluxes
                     gap_mortality_n_to_litr_met_n(c,j) = gap_mortality_n_to_litr_met_n(c,j) + &
                          m_retransn_to_litter(p) * wtcol(p) * leaf_prof(p,j)
                     ! storage N pool gap mortality fluxes
                     gap_mortality_n_to_litr_met_n(c,j) = gap_mortality_n_to_litr_met_n(c,j) + &
                          m_npool_to_litter(p) * wtcol(p) * leaf_prof(p,j)

                     ! storage gap mortality nitrogen fluxes
                     gap_mortality_n_to_litr_met_n(c,j)      = gap_mortality_n_to_litr_met_n(c,j)      + &
                          m_leafn_storage_to_litter(p)      * wtcol(p) * leaf_prof(p,j)
                     gap_mortality_n_to_litr_met_n(c,j)     = gap_mortality_n_to_litr_met_n(c,j)     + &
                          m_frootn_storage_to_litter(p)     * wtcol(p) * froot_prof(p,j)
                     gap_mortality_n_to_litr_met_n(c,j)  = gap_mortality_n_to_litr_met_n(c,j)  + &
                          (m_livestemn_storage_to_litter(p) + m_deadstemn_storage_to_litter(p))  * wtcol(p) * stem_prof(p,j)
                     gap_mortality_n_to_litr_met_n(c,j) = gap_mortality_n_to_litr_met_n(c,j) + &
                          (m_livecrootn_storage_to_litter(p) + m_deadcrootn_storage_to_litter(p)) * wtcol(p) * croot_prof(p,j)

                     ! transfer gap mortality nitrogen fluxes
                     gap_mortality_n_to_litr_met_n(c,j)      = gap_mortality_n_to_litr_met_n(c,j)      + &
                          m_leafn_xfer_to_litter(p)      * wtcol(p) * leaf_prof(p,j)
                     gap_mortality_n_to_litr_met_n(c,j)     = gap_mortality_n_to_litr_met_n(c,j)     + &
                          m_frootn_xfer_to_litter(p)     * wtcol(p) * froot_prof(p,j)
                     gap_mortality_n_to_litr_met_n(c,j)  = gap_mortality_n_to_litr_met_n(c,j)  + &
                          (m_livestemn_xfer_to_litter(p) + m_deadstemn_xfer_to_litter(p))  * wtcol(p) * stem_prof(p,j)
                     gap_mortality_n_to_litr_met_n(c,j) = gap_mortality_n_to_litr_met_n(c,j) + &
                          (m_livecrootn_xfer_to_litter(p) + m_deadcrootn_xfer_to_litter(p)) * wtcol(p) * croot_prof(p,j)

                     ! leaf gap mortality phosphorus fluxes
                     gap_mortality_p_to_litr_met_p(c,j) = gap_mortality_p_to_litr_met_p(c,j) + &
                          m_leafp_to_litter(p) * lf_flab(ivt(p)) * wtcol(p) * leaf_prof(p,j)
                     gap_mortality_p_to_litr_cel_p(c,j) = gap_mortality_p_to_litr_cel_p(c,j) + &
                          m_leafp_to_litter(p) * lf_fcel(ivt(p)) * wtcol(p) * leaf_prof(p,j)
                     gap_mortality_p_to_litr_lig_p(c,j) = gap_mortality_p_to_litr_lig_p(c,j) + &
                          m_leafp_to_litter(p) * lf_flig(ivt(p)) * wtcol(p) * leaf_prof(p,j)

                     ! fine root litter phosphorus fluxes
                     gap_mortality_p_to_litr_met_p(c,j) = gap_mortality_p_to_litr_met_p(c,j) + &
                          m_frootp_to_litter(p) * fr_flab(ivt(p)) * wtcol(p) * froot_prof(p,j)
                     gap_mortality_p_to_litr_cel_p(c,j) = gap_mortality_p_to_litr_cel_p(c,j) + &
                          m_frootp_to_litter(p) * fr_fcel(ivt(p)) * wtcol(p) * froot_prof(p,j)
                     gap_mortality_p_to_litr_lig_p(c,j) = gap_mortality_p_to_litr_lig_p(c,j) + &
                          m_frootp_to_litter(p) * fr_flig(ivt(p)) * wtcol(p) * froot_prof(p,j)

                     ! wood gap mortality phosphorus fluxes
                     gap_mortality_p_to_cwdp(c,j)  = gap_mortality_p_to_cwdp(c,j)  + &
                          (m_livestemp_to_litter(p) + m_deadstemp_to_litter(p))  * wtcol(p) * stem_prof(p,j)
                     gap_mortality_p_to_cwdp(c,j) = gap_mortality_p_to_cwdp(c,j) + &
                          (m_livecrootp_to_litter(p) + m_deadcrootp_to_litter(p)) * wtcol(p) * croot_prof(p,j)

                     ! retranslocated N pool gap mortality fluxes
                     gap_mortality_p_to_litr_met_p(c,j) = gap_mortality_p_to_litr_met_p(c,j) + &
                          m_retransp_to_litter(p) * wtcol(p) * leaf_prof(p,j)
                     gap_mortality_p_to_litr_met_p(c,j) = gap_mortality_p_to_litr_met_p(c,j) + &
                          m_ppool_to_litter(p) * wtcol(p) * leaf_prof(p,j)


                     ! storage gap mortality phosphorus fluxes
                     gap_mortality_p_to_litr_met_p(c,j)      = gap_mortality_p_to_litr_met_p(c,j)      + &
                          m_leafp_storage_to_litter(p)      * wtcol(p) * leaf_prof(p,j)
                     gap_mortality_p_to_litr_met_p(c,j)     = gap_mortality_p_to_litr_met_p(c,j)     + &
                          m_frootp_storage_to_litter(p)     * wtcol(p) * froot_prof(p,j)
                     gap_mortality_p_to_litr_met_p(c,j)  = gap_mortality_p_to_litr_met_p(c,j)  + &
                          (m_livestemp_storage_to_litter(p) + m_deadstemp_storage_to_litter(p))  * wtcol(p) * stem_prof(p,j)
                     gap_mortality_p_to_litr_met_p(c,j) = gap_mortality_p_to_litr_met_p(c,j) + &
                          (m_livecrootp_storage_to_litter(p) + m_deadcrootp_storage_to_litter(p)) * wtcol(p) * croot_prof(p,j)

                     ! transfer gap mortality phosphorus fluxes
                     gap_mortality_p_to_litr_met_p(c,j)      = gap_mortality_p_to_litr_met_p(c,j)      + &
                          m_leafp_xfer_to_litter(p)      * wtcol(p) * leaf_prof(p,j)
                     gap_mortality_p_to_litr_met_p(c,j)     = gap_mortality_p_to_litr_met_p(c,j)     + &
                          m_frootp_xfer_to_litter(p)     * wtcol(p) * froot_prof(p,j)
                     gap_mortality_p_to_litr_met_p(c,j)  = gap_mortality_p_to_litr_met_p(c,j)  + &
                          (m_livestemp_xfer_to_litter(p) + m_deadstemp_xfer_to_litter(p))  * wtcol(p) * stem_prof(p,j)
                     gap_mortality_p_to_litr_met_p(c,j) = gap_mortality_p_to_litr_met_p(c,j) + &
                          (m_livecrootp_xfer_to_litter(p) + m_deadcrootp_xfer_to_litter(p)) * wtcol(p) * croot_prof(p,j)

                  end if
               end if

            end do
         end do
      end do

    end associate

  end subroutine CNGapPftToColumn

  subroutine mortality_rate_soilorder(&
       num_soilp, filter_soilp, &
       cnstate_vars)
    !
    ! !DESCRIPTION:
    ! !this surroutine is to calculate mortality rate based on soil order

    ! USES
      !$acc routine seq
    use pftvarcon       , only: woody, needleleaf, climatezone
    use soilorder_varcon, only: r_mort_soilorder

    !
    ! !ARGUMENTS:
    integer                  , intent(in)    :: num_soilp       ! number of soil patches in filter
    integer                  , intent(in)    :: filter_soilp(:) ! patch filter for soil points
    type(cnstate_type)       , intent(inout)    :: cnstate_vars

    ! local variables
    integer :: p,c,fp


    associate(                                                      &
       ivt            =>    veg_pp%itype                             , & ! Input:[integer  (:)   ]  patch vegetation type
       isoilorder     =>    cnstate_vars%isoilorder               , &
       r_mort_cal     =>    cnstate_vars%r_mort_cal_patch )

       ! loop over the patches
       do fp = 1,num_soilp
          p = filter_soilp(fp)
          c = veg_pp%column(p)
               ! broadleaf tropical trees
               if( woody(veg_pp%itype(p)) == 1.0_r8 .and. &
                   needleleaf(veg_pp%itype(p)) == 0 .and. &
                   climatezone(veg_pp%itype(p)) == 1 )then
                   r_mort_cal(p) = r_mort_soilorder( isoilorder(c) )
               else
                   r_mort_cal(p) = 0.02_r8                 ! Default mortality rate
               endif
       end do

     end associate


  end subroutine mortality_rate_soilorder


end module GapMortalityMod

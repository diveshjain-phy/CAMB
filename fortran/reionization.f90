

    module Reionization
    use Precision
    use MiscUtils
    use classes
    use results
    implicit none
    private
    real(dl), parameter :: TTanhReionization_DefFraction = -1._dl
    !if -1 set from YHe assuming Hydrogen and first ionization of Helium follow each other

    real(dl) :: Tanh_zexp = 1.5_dl
! start reionhist
    integer, parameter :: reionbins=150
! end reionhist
    type, extends(TReionizationModel) :: TTanhReionization
        logical    :: use_optical_depth = .false.
        real(dl)   :: redshift = 10._dl ! the redshift corresponding to mid point of reionization
        real(dl)   :: optical_depth = 0._dl
        real(dl)   :: delta_redshift = 0.5_dl
        real(dl)   :: fraction = TTanhReionization_DefFraction
        !Parameters for the second reionization of Helium
        logical    :: include_helium_fullreion  = .true.
        real(dl)   :: helium_redshift  = 3.5_dl
        real(dl)   :: helium_delta_redshift  = 0.4_dl
        real(dl)   :: helium_redshiftstart  = 5.5_dl
        real(dl)   :: tau_solve_accuracy_boost = 1._dl
        real(dl)   :: timestep_boost =  1._dl
        real(dl)   :: max_redshift = 50._dl
! start reionhist
        logical :: Usereionhist=.false.
        integer :: rebins = reionbins
        real(c_double) :: xei(reionbins) ! do i need default values for these array?
        real(c_double) :: zi(reionbins)
        real(c_double) :: taui(reionbins) !just for consistency check?
! end reionhist    
        !The rest are internal to this module.
        real(dl), private ::  fHe, WindowVarMid, WindowVarDelta
        class(CAMBdata), pointer :: State
    contains
    procedure :: ReadParams => TTanhReionization_ReadParams
    procedure :: Init => TTanhReionization_Init
    procedure :: x_e => TTanhReionization_xe
    procedure :: get_timesteps => TTanhReionization_get_timesteps
    procedure, nopass :: SelfPointer => TTanhReionization_SelfPointer
    procedure, nopass ::  GetZreFromTau => TTanhReionization_GetZreFromTau
    procedure, private :: SetParamsForZre => TTanhReionization_SetParamsForZre
    procedure, private :: zreFromOptDepth => TTanhReionization_zreFromOptDepth
    end type TTanhReionization

    public TTanhReionization
    contains

    real(dl) function interp1d_single_dp(x1,y1,x2,y2,xval) result(yval)
	    real(dl),intent(in) :: x1,y1,x2,y2,xval
	    real(dl) :: frac
	    frac = ( xval - x1 ) / ( x2 - x1 )
	    yval = y1 + frac * ( y2 - y1 )
    end function interp1d_single_dp
    function TTanhReionization_xe(this, z, tau, xe_recomb)
    !a and time tau and redundant, both provided for convenience
    !xe_recomb is xe(tau_start) from recombination (typically very small, ~2e-4)
    !xe should map smoothly onto xe_recomb
    class(TTanhReionization) :: this
    real(dl), intent(in) :: z
    real(dl), intent(in), optional :: tau, xe_recomb
    real(dl) TTanhReionization_xe
    real(dl) tgh, xod
    real(dl) xstart
! start reionhist
    integer :: zbini
! end reionhist
    xstart = PresentDefault( 0._dl, xe_recomb)
    this%fHe=8.d-2
    xod = (this%WindowVarMid - (1+z)**Tanh_zexp)/this%WindowVarDelta
    if (xod > 100) then
        tgh=1.d0
    else
        tgh=tanh(xod)
    end if
    if (.not.this%Usereionhist) then  ! not using the reionization history scheme
        TTanhReionization_xe =(this%fraction-xstart)*(tgh+1._dl)/2._dl+xstart
        
    end if
    if (this%include_helium_fullreion .and. z < this%helium_redshiftstart .and. .not.this%Usereionhist) then

        !Effect of Helium becoming fully ionized is small so details not important
        xod = (this%helium_redshift - z)/this%helium_delta_redshift
        if (xod > 100) then
            tgh=1.d0
        else
            tgh=tanh(xod)
        end if

        TTanhReionization_xe =  TTanhReionization_xe + this%fHe*(tgh+1._dl)/2._dl 
    end if

! start reion_hist
    if (this%Usereionhist) then  ! using the reionization history scheme
           do zbini = 1, this%rebins
              if (this%xei(zbini).eq.0._dl) this%xei(zbini) = max(xstart,1.d-10)
           end do
           zbini = 1
           if (z < this%zi(1) .and. z>this%zi(this%rebins)) then
              do while (this%zi(zbini)>z .and. zbini/=this%rebins-1)
                 zbini = zbini+1
              end do
              if (zbini.eq.1) then
                   TTanhReionization_xe=xstart
              else
                   TTanhReionization_xe=interp1d_single_dp(this%zi(zbini-1),this%xei(zbini-1),this%zi(zbini),this%xei(zbini),z)
              end if
           else if (z>this%zi(1)) then
                   TTanhReionization_xe=xstart
           else if (z<this%zi(this%rebins)) then
                   TTanhReionization_xe=1._dl

           end if
           if (this%include_helium_fullreion .and. z < 3.0) then
                   TTanhReionization_xe =  TTanhReionization_xe *1.16
           else
                   TTanhReionization_xe =  TTanhReionization_xe *1.08
           end if
    end if
!end reon_hist
    end function TTanhReionization_xe

    subroutine TTanhReionization_get_timesteps(this, n_steps, z_start, z_complete)
    !minimum number of time steps to use between tau_start and tau_complete
    !Scaled by AccuracyBoost later
    !steps may be set smaller than this anyway
    class(TTanhReionization) :: this
    integer, intent(out) :: n_steps
    real(dl), intent(out):: z_start, z_Complete
    !PRINT *,"ARE WE IN TIME STEPS"
    if (this%Usereionhist) then
	    n_steps = nint(50 * this%timestep_boost)
	    z_start = this%zi(1)! this%redshift + this%delta_redshift*8!(2.*this%zi(this%rebins)-this%zi(this%rebins-1))!this%redshift + this%delta_redshift*8
	    z_complete =this%zi(this%rebins)!max(0.d0,this%redshift-this%delta_redshift*8)!(2.*this%zi(1)-this%zi(2))! 
    else
	    n_steps = nint(50 * this%timestep_boost)
	    z_start =  this%redshift + this%delta_redshift*8!(2.*this%zi(this%rebins)-this%zi(this%rebins-1))!this%redshift + this%delta_redshift*8
	    z_complete =max(0.d0,this%redshift-this%delta_redshift*8)!(2.*this%zi(1)-this%zi(2))
    end if     
    end subroutine TTanhReionization_get_timesteps

    subroutine TTanhReionization_ReadParams(this, Ini)
    use IniObjects
    class(TTanhReionization) :: this
    class(TIniFile), intent(in) :: Ini

    this%Reionization = Ini%Read_Logical('reionization')
    !PRINT *,"ARE WE PARAMETERIZING?"
    if (this%Reionization) then

        this%use_optical_depth = Ini%Read_Logical('re_use_optical_depth')

        if (this%use_optical_depth) then
            this%optical_depth = Ini%Read_Double('re_optical_depth')
        else
            this%redshift = Ini%Read_Double('re_redshift')
        end if

        call Ini%Read('re_delta_redshift',this%delta_redshift)
        call Ini%Read('re_ionization_frac',this%fraction)
        call Ini%Read('re_helium_redshift',this%helium_redshift)
        call Ini%Read('re_helium_delta_redshift',this%helium_delta_redshift)

        this%helium_redshiftstart  = Ini%Read_Double('re_helium_redshiftstart', &
            this%helium_redshift + 5*this%helium_delta_redshift)

    end if

    end subroutine TTanhReionization_ReadParams

    subroutine TTanhReionization_SetParamsForZre(this)
    class(TTanhReionization) :: this
    if (.not.this%Usereionhist) then 
    	this%WindowVarMid = (1._dl+this%redshift)**Tanh_zexp
    	this%WindowVarDelta = Tanh_zexp*(1._dl+this%redshift)**(Tanh_zexp-1._dl)*this%delta_redshift
    end if
    end subroutine TTanhReionization_SetParamsForZre

    subroutine TTanhReionization_Init(this, State)
    use constants
    use MathUtils
    class(TTanhReionization) :: this
    class(TCAMBdata), target :: State
    procedure(obj_function) :: dtauda

    select type (State)
    class is (CAMBdata)
        this%State => State

        this%fHe = 8.d-2! State%CP%YHe/(mass_ratio_He_H*(1.d0-State%CP%YHe))
        if (this%Reionization) then

            if (this%optical_depth /= 0._dl .and. .not. this%use_optical_depth .and. .not. this%Usereionhist) &
                write (*,*) 'WARNING: You seem to have set the optical depth, but use_optical_depth = F'

            if (this%use_optical_depth.and.this%optical_depth<0.001 &
                .or. .not.this%use_optical_depth .and. this%Redshift<0.001) then
                this%Reionization = .false.
            end if

        end if

        if (this%Reionization) then

            if (this%fraction==TTanhReionization_DefFraction) &
                this%fraction = 1._dl + this%fHe  !H + singly ionized He

            if (this%use_optical_depth) then
                this%redshift = 0
                call this%zreFromOptDepth()
                if (global_error_flag/=0) return
                if (FeedbackLevel > 0) write(*,'("Reion redshift       =  ",f6.3)') this%redshift
            end if

            call this%SetParamsForZre()

            !this is a check, agrees very well in default parameterization
            if (.not. this%Usereionhist) then
            	if (FeedbackLevel > 1) write(*,'("Integrated opt depth = ",f7.4)') this%State%GetReionizationOptDepth()
            end if

        end if
    end select
    end subroutine TTanhReionization_Init

    subroutine TTanhReionization_Validate(this, OK)
    class(TTanhReionization),intent(in) :: this
    logical, intent(inout) :: OK
    if (.not.this%Usereionhist) then 
	    if (this%Reionization) then
		if (this%use_optical_depth) then
		    if (this%optical_depth<0 .or. this%optical_depth > 0.9  .or. &
		        this%include_helium_fullreion .and. this%optical_depth<0.01) then
		        OK = .false.
		        write(*,*) 'Optical depth is strange. You have:', this%optical_depth
		    end if
		else
		    if (this%redshift < 0 .or. this%Redshift +this%delta_redshift*3 > this%max_redshift .or. &
		        this%include_helium_fullreion .and. this%redshift < this%helium_redshift) then
		        OK = .false.
		        write(*,*) 'Reionization redshift strange. You have: ',this%Redshift
		    end if
		end if
		if (this%fraction/= TTanhReionization_DefFraction .and. (this%fraction < 0 .or. this%fraction > 1.5)) then
		    OK = .false.
		    write(*,*) 'Reionization fraction strange. You have: ',this%fraction
		end if
		if (this%delta_redshift > 3 .or. this%delta_redshift<0.1 ) then
		    !Very narrow windows likely to cause problems in interpolation etc.
		    !Very broad likely to conflict with quasar data at z=6
		    OK = .false.
		    write(*,*) 'Reionization delta_redshift is strange. You have: ',this%delta_redshift
		end if
    end if
    end if

    end subroutine TTanhReionization_Validate

    subroutine TTanhReionization_zreFromOptDepth(this)
    !General routine to find zre parameter given optical depth
    class(TTanhReionization) :: this
    real(dl) try_b, try_t
    real(dl) tau, last_top, last_bot
    integer i
    try_b = 0
    try_t = this%max_redshift
    i=0
    if (.not. this%Usereionhist) then



	    do
		i=i+1
		this%redshift = (try_t + try_b)/2
		call this%SetParamsForZre()
		tau = this%State%GetReionizationOptDepth()

		if (tau > this%optical_depth) then
		    try_t = this%redshift
		    last_top = tau
		else
		    try_b = this%redshift
		    last_bot = tau
		end if
		if (abs(try_b - try_t) < 1e-2_dl/this%tau_solve_accuracy_boost) then
		    if (try_b==0) last_bot = 0
		    if (try_t/=this%max_redshift) this%redshift  = &
		        (try_t*(this%optical_depth-last_bot) + try_b*(last_top-this%optical_depth))/(last_top-last_bot)
		    exit
		end if
		if (i>100) call GlobalError('TTanhReionization_zreFromOptDepth: failed to converge',error_reionization)
	    end do

	    if (abs(tau - this%optical_depth) > 0.002 .and. global_error_flag==0) then
		write (*,*) 'TTanhReionization_zreFromOptDepth: Did not converge to optical depth'
		write (*,*) 'tau =',tau, 'optical_depth = ', this%optical_depth
		write (*,*) try_t, try_b
		write (*,*) '(If running a chain, have you put a constraint on tau?)'
		call GlobalError('Reionization did not converge to optical depth',error_reionization)
	    end if
    end if 
    end subroutine TTanhReionization_zreFromOptDepth

    real(dl) function TTanhReionization_GetZreFromTau(P, tau)
    type(CAMBparams) :: P, P2
    real(dl) tau
    integer error
    type(CAMBdata) :: State

    P2 = P

    select type(Reion=>P2%Reion)
    class is (TTanhReionization)
        Reion%Reionization = .true.
        Reion%use_optical_depth = .true.
        Reion%optical_depth = tau
    end select
    call State%SetParams(P2,error)
    if (error/=0)  then
        TTanhReionization_GetZreFromTau = -1
    else
        select type(Reion=>State%CP%Reion)
        class is (TTanhReionization)
            TTanhReionization_GetZreFromTau = Reion%redshift
        end select
    end if

    end function TTanhReionization_GetZreFromTau

    subroutine TTanhReionization_SelfPointer(cptr,P)
    use iso_c_binding
    Type(c_ptr) :: cptr
    Type (TTanhReionization), pointer :: PType
    class (TPythonInterfacedClass), pointer :: P

    call c_f_pointer(cptr, PType)
    P => PType

    end subroutine TTanhReionization_SelfPointer

    end module Reionization

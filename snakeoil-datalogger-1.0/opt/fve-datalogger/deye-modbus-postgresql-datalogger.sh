#!/bin/bash
# Čtení dat ze střídače Deye přes RS485/modbus a ukládání do PostgreSQL
#
# spouštět z cronu 1x za minutu
set -e

# config
cd $(dirname "${BASH_SOURCE[0]}")
source datalogger.conf.default
[ -f datalogger.conf ] && source datalogger.conf

# Ktery stridac? (1, 2, 3, ...)
N=${1:-1}

# cist z USB/RS485 prevodniku (https://pypi.org/project/modbus-cli/ a https://github.com/3cky/mbusd)
# viz /etc/mbusd/mbusd*conf
PORT=$((1110+$N))
MODBUS="localhost:$PORT"

cd

SQL_BUFFER_FILE="datalogger-buffer/deye-modbus-datalogger-$N.sql"

# okamzite hodnoty (1x za minutu)
REGISTRY1="142/h 336/h $(
  seq 541 591 | sed 's:$:/h:';
  seq 598 679 | sed 's:$:/h:'
)"

# inverter_W 636/h
# PV1_W 672/h
# PV1_V 676/h
# PV1_A 677/h
# PV2_W 673/h
# PV2_V 678/h
# PV2_A 679/h
# Gen_W 667/h
# Batt_temp 586/h
# Batt_V 587/h
# Batt_SOC 588/h
# Batt_W 590/h
# Batt_A 591/h
# AC_Relay_status 552/h
# Load_Power 653/h -- nefunguje pri prodeji do site
# Load_Power = Grid_CT_Power - Grid_Inner_Power
# Grid_CT_Power H@619/h
# Grid_Inner_Power H@607/h

# denni statistiky
REGISTRY2="529/h 514/h 515/h 526/h 520/h 521/h"
# Day_Battery_Charge 514/h
# Day_Battery_Discharge 515/h
# Day_Load_Energy 526/h
# Day_PV_Energy 529/h
# Day_Grid_Import 520/h
# Day_Grid_Export 521/h

sql_insert_or_later() {
  Q=${1//[$'\n']}

  if ! echo "$Q" | timeout 40 psql "$PSQL_URI" >> /dev/null
  then
    [ -d $(dirname $SQL_BUFFER_FILE) ] || mkdir -p $(dirname $SQL_BUFFER_FILE)
    echo "$Q" >> $SQL_BUFFER_FILE
  fi
}

READOUT=$(\
  modbus -s${N} $MODBUS $REGISTRY1 |\
  grep -v ^Parsed |\
  sed -r 's/^([0-9]{3}): (-?[0-9]*).*/R\1=\2;/' \
)

# echo "-- read from $MODBUS --"
# echo $READOUT
# echo "-------------------------------"

eval $READOUT

R541=$(calc -- "$R541/10-100")
R586=$(calc -- "$R586/10-100")
R587=$(calc -- "$R587/100")
R591=$(calc -- "-1*$R591/100")
R590=$(calc -- "-1*$R590")
R667=$(calc -- "max($R667,0)")
R676=$(calc -- "$R676/10")
R677=$(calc -- "$R677/10")
R678=$(calc -- "$R678/10")
R679=$(calc -- "$R679/10")
PARALLEL_ENABLED=$(($R336 & 0x01))

AC_INV_Relay_Status=$(($R552 >> 0 & 1))
AC_Undefined_Load_Relay_Status=$(($R552 >> 1 & 1))
AC_Grid_Relay_Status=$(($R552 >> 2 & 1))
AC_Generator_Relay_Status=$(($R552 >> 3 & 1))
AC_Grid_Give_Power_to_Relay_Status=$(($R552 >> 4 & 1))
AC_Dry_Contact1_Status=$(($R552 >> 5 & 1))
AC_Dry_Contact2_Status=$(($R552 >> 6 & 1))

NOW=$(date +'%Y-%m-%d %H:%M:%S %z')

# Pri zapojeni "spotreba na LOADu" jsou v registrech pouzitelny hodnoty:
LOAD_W="$R653"
GRID_W=$((-1 * $R625))

if [ "$LOAD_POWER_ON_GRID_SIDE_HACK" = "true" ]
then
  # Zapojeni: "spotreba na GRIDu" + CT mereni
  # Hack: vypocet spotreby (load power) a site (grid power)

  # Pri zapojeni "spotreba na GRIDu" firmware 1128
  # LOAD_W=$(($R619 - $R607))
  # LOAD_W=$((LOAD_W > 0 ? $LOAD_W : 0));

  # LOAD_W="$R653"

  # Pri zapojeni "spotreba na GRIDu", firmware 1172, standalone mode
  # LOAD_W=$(($R619 - $R607))

  # Pri zapojeni "spotreba na GRIDu", firmware 1172, parallel mode
  # (stejne to ukazuje blbe)

  if [ $R142 = "0" ] # Selling First
  then
    if [ $PARALLEL_ENABLED == '1' ]; then
      # Pri zapojeni "spotreba na GRIDu", firmware 1172, parallel mode
      Grid_L1_V=$(calc -- "$R598/10")
      Grid_L2_V=$(calc -- "$R599/10")
      Grid_L3_V=$(calc -- "$R600/10")

      # Inner Side of Grid
      Grid_L1_A=$(calc -- "$R610/100")
      Grid_L2_A=$(calc -- "$R611/100")
      Grid_L3_A=$(calc -- "$R612/100")
      Grid_L1_W=$(calc -- "$Grid_L1_V*$Grid_L1_A")
      Grid_L2_W=$(calc -- "$Grid_L2_V*$Grid_L2_A")
      Grid_L3_W=$(calc -- "$Grid_L3_V*$Grid_L3_A")
      Grid_W=$(calc -- "$Grid_L1_W+$Grid_L2_W+$Grid_L3_W")

      # CT sensors
      Grid_CT_L1_A=$(calc -- "$R613/100")
      Grid_CT_L2_A=$(calc -- "$R614/100")
      Grid_CT_L3_A=$(calc -- "$R615/100")
      Grid_CT_L1_W=$(calc -- "$Grid_L1_V*$Grid_CT_L1_A")
      Grid_CT_L2_W=$(calc -- "$Grid_L2_V*$Grid_CT_L2_A")
      Grid_CT_L3_W=$(calc -- "$Grid_L3_V*$Grid_CT_L3_A")
      Grid_CT_W=$(calc -- "$Grid_CT_L1_W+$Grid_CT_L2_W+$Grid_CT_L3_W")

      LOAD_W=$(calc -- "round($Grid_W - $Grid_CT_W)" | tr -d '\t')
      GRID_W=$Grid_CT_W
    else 
      # Pri zapojeni "spotreba na GRIDu", firmware 1172, standalone mode
      LOAD_W=$(($R619 - $R607))
      GRID_W=$((-1 * $R619))
    fi
    # LOAD_W=$((LOAD_W > 0 ? $LOAD_W : 0));
  fi

  if [ $R142 = "1" ] # Zero Export to LOAD
  then
    LOAD_W="$R653"
    GRID_W=$((-1 * $R619))
  fi

  if [ $R142 = "2" ] # Zero Export to CT
  then
    if [ $PARALLEL_ENABLED == '1' ]; then
      # nevim, v registru 653 jsou hausnumera
      LOAD_W="$R653"
    else
      LOAD_W="$R653"
    fi
    GRID_W=$((-1 * $R619))
  fi
fi

READOUT_SQL="INSERT INTO deye_datalog
  (timestamp, unit_id, inverter_w, pv1_w, pv2_w, gen_w, batt_temp, batt_v, batt_soc, batt_w, batt_a, radiator_temp, load_w, grid_w, pv1_v, pv1_a, pv2_v, pv2_a)
  VALUES ('$NOW', $N, $R636, $R672, $R673, $R667, $R586, $R587, $R588, $R590, $R591, $R541, $LOAD_W, $GRID_W, $R676, $R677, $R678, $R679);
"

sql_insert_or_later "$READOUT_SQL"

# zapisovat statistiky - denni soucty (jen pri zmene, tj cca po 10 minutach)
NOW=$(date +'%Y-%m-%d %H:%M:%S %z')

READOUT=$(\
  modbus -s${N} $MODBUS $REGISTRY2 |\
  grep -v ^Parsed |\
  sed -r 's/^([0-9]{3}): (-?[0-9]*).*/R\1=\2;/' \
)
# echo "-- read from $MODBUS --"
# echo $READOUT
# echo "-------------------------------"

eval $READOUT

R529=$(calc -- "$R529/10")
R514=$(calc -- "$R514/10")
R515=$(calc -- "$R515/10")
R526=$(calc -- "$R526/10")
R520=$(calc -- "$R520/10")
R521=$(calc -- "$R521/10")

BASES_SQL="SELECT day_pv_kwh, day_batt_charge, day_batt_discharge, day_load_energy, day_grid_export, day_grid_import FROM deye_datalog_daily WHERE unit_id=${N} ORDER BY timestamp DESC LIMIT 1"
IFS='|' read day_pv_kwh day_batt_charge day_batt_discharge day_load_energy day_grid_export day_grid_import <<< $(echo $BASES_SQL | psql --no-align -t "$PSQL_URI" | grep -v ^$ | ifne -n echo 'no_db|0|0|0|0|0')

# Zapsat do DB jedine pokud od minule jsou jina cisla. Stridace DEYE SUN to updatujou cca po 10 minutach
if ! (( `echo "$day_pv_kwh == $R529 && $day_batt_charge == $R514 && $day_batt_discharge == $R515 && $day_load_energy == $R526 && $day_grid_export == $R521 && $day_grid_import == $R520" | bc -l` ))
then
  READOUT_SQL="INSERT INTO deye_datalog_daily
    (timestamp, unit_id, day_pv_kwh, day_batt_charge, day_batt_discharge, day_load_energy, day_grid_export, day_grid_import)
    VALUES ('$NOW', $N, $R529, $R514, $R515, $R526, $R521, $R520);
  "

  sql_insert_or_later "$READOUT_SQL"
fi

#
# zpozdeny insert pokud je neco v bufferu
#
(
  [ -f $SQL_BUFFER_FILE ] || exit

  if cat $SQL_BUFFER_FILE | timeout 30 psql "$PSQL_URI" >> /dev/null
  then
    rm $SQL_BUFFER_FILE
  fi
) &

: '
CREATE TABLE "public"."deye_datalog" (
    "timestamp" timestamptz,
    "unit_id" numeric(2) default 1,
    "pv1_w" numeric(7,2),
    "pv2_w" numeric(7,2),
    "pv1_v" numeric(7,2),
    "pv2_v" numeric(7,2),
    "pv1_a" numeric(7,2),
    "pv2_a" numeric(7,2),
    "batt_soc" numeric(7,2),
    "batt_w" numeric(7,2),
    "batt_v" numeric(7,2),
    "batt_a" numeric(7,2),
    "batt_temp" numeric(7,2),
    "radiator_temp" numeric(7,2),
    "inverter_w" numeric(7,2),
    "gen_w" numeric(7,2),
    "grid_w" numeric(7,2),
    "load_w" numeric(7,2)
);
CREATE INDEX deye_datalog__timestamp ON deye_datalog(timestamp);

CREATE TABLE "public"."deye_datalog_daily" (
    "timestamp" timestamptz,
    "unit_id" numeric(2) default 1,
    "day_pv_kwh" numeric(7,2),
    "day_load_energy" numeric(7,2),
    "day_grid_export" numeric(7,2),
    "day_grid_import" numeric(7,2),
    "day_batt_charge" numeric(7,2),
    "day_batt_discharge" numeric(7,2)
);
CREATE INDEX deye_datalog_daily__timestamp ON deye_datalog_daily(timestamp);

'


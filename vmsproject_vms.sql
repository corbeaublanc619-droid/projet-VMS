--
-- PostgreSQL database dump
--

\restrict FmQc9AG46FCbo8mrbeRxLH5BFd83Th17wRHsd08rAFNc2Mgqc5rgpB9XHhZ5iKZ

-- Dumped from database version 16.13
-- Dumped by pg_dump version 18.3

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: vmsproject
--

-- *not* creating schema, since initdb creates it


ALTER SCHEMA public OWNER TO vmsproject;

--
-- Name: vms; Type: SCHEMA; Schema: -; Owner: vmsproject
--

CREATE SCHEMA vms;


ALTER SCHEMA vms OWNER TO vmsproject;

--
-- Name: client_status; Type: TYPE; Schema: vms; Owner: vmsproject
--

CREATE TYPE vms.client_status AS ENUM (
    'active',
    'inactive',
    'suspendu'
);


ALTER TYPE vms.client_status OWNER TO vmsproject;

--
-- Name: demande_status; Type: TYPE; Schema: vms; Owner: vmsproject
--

CREATE TYPE vms.demande_status AS ENUM (
    'initiee',
    'payee',
    'approuvee',
    'refusee',
    'terminee'
);


ALTER TYPE vms.demande_status OWNER TO vmsproject;

--
-- Name: user_role; Type: TYPE; Schema: vms; Owner: vmsproject
--

CREATE TYPE vms.user_role AS ENUM (
    'admin',
    'manager',
    'issuer',
    'approver',
    'agent'
);


ALTER TYPE vms.user_role OWNER TO vmsproject;

--
-- Name: user_status; Type: TYPE; Schema: vms; Owner: vmsproject
--

CREATE TYPE vms.user_status AS ENUM (
    'active',
    'inactive',
    'blocked'
);


ALTER TYPE vms.user_status OWNER TO vmsproject;

--
-- Name: voucher_status; Type: TYPE; Schema: vms; Owner: vmsproject
--

CREATE TYPE vms.voucher_status AS ENUM (
    'draft',
    'issued',
    'redeemed',
    'expired',
    'cancelled'
);


ALTER TYPE vms.voucher_status OWNER TO vmsproject;

--
-- Name: check_voucher_before_redemption(); Type: FUNCTION; Schema: public; Owner: vmsproject
--

CREATE FUNCTION public.check_voucher_before_redemption() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF OLD.status_vouch = 'redeemed' THEN
        RAISE EXCEPTION 'Voucher déjà utilisé (ref=%)', OLD.ref_voucher;
    END IF;

    IF OLD.expire_date < CURRENT_TIMESTAMP THEN
        RAISE EXCEPTION 'Voucher expiré (%).', OLD.expire_date;
    END IF;

    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.check_voucher_before_redemption() OWNER TO vmsproject;

--
-- Name: generate_vouchers_for_demande(integer); Type: FUNCTION; Schema: public; Owner: vmsproject
--

CREATE FUNCTION public.generate_vouchers_for_demande(p_demande_id integer) RETURNS TABLE(ref_voucher integer, no_voucher character varying, montant numeric, status_vouch character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_nb_voucher INTEGER;
    v_valeur_voucher NUMERIC(12,2);
    v_client_id INTEGER;
    v_duree INTEGER;
    v_issue_date TIMESTAMP;
    v_expire_date TIMESTAMP;
    v_qr_content TEXT;
    v_voucher_no VARCHAR(100);
    v_counter INTEGER;
    v_timestamp VARCHAR(20);
BEGIN
    SELECT d.nb_voucher, d.valeur_voucher, d.client_id,
           COALESCE(d.duree, 365)
    INTO v_nb_voucher, v_valeur_voucher, v_client_id, v_duree
    FROM demande d
    WHERE d.ref_demande = p_demande_id
      AND d.statut = 'approuvee';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Demande non trouvée ou non approuvée: %', p_demande_id;
    END IF;

    v_issue_date  := CURRENT_TIMESTAMP;
    v_expire_date := v_issue_date + (v_duree || ' days')::INTERVAL;
    v_timestamp   := TO_CHAR(CURRENT_TIMESTAMP, 'YYYYMMDDHH24MISS');

    FOR v_counter IN 1..v_nb_voucher LOOP
        v_voucher_no := 'VCH-' || p_demande_id || '-' || v_timestamp || '-' || v_counter;
        v_qr_content := 'VMS|VOUCHER|' || v_voucher_no;

        INSERT INTO voucher (
            no_voucher, montant, issue_date, expire_date,
            qr_code, status_vouch, client_id, demande_id
        )
        VALUES (
            v_voucher_no,
            v_valeur_voucher,
            v_issue_date,
            v_expire_date,
            v_qr_content,
            'emis',
            v_client_id,
            p_demande_id
        )
        RETURNING
            ref_voucher,
            no_voucher,
            montant,
            status_vouch
        INTO
            ref_voucher,
            no_voucher,
            montant,
            status_vouch;

        RETURN NEXT;
    END LOOP;

    UPDATE demande
    SET status_demande = 'vouchers_generes'
    WHERE ref_demande = p_demande_id;

    RETURN;
END;
$$;


ALTER FUNCTION public.generate_vouchers_for_demande(p_demande_id integer) OWNER TO vmsproject;

--
-- Name: update_user_updated_at(); Type: FUNCTION; Schema: public; Owner: vmsproject
--

CREATE FUNCTION public.update_user_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$

BEGIN

    NEW.updated_at = CURRENT_TIMESTAMP;

    RETURN NEW;

END;

$$;


ALTER FUNCTION public.update_user_updated_at() OWNER TO vmsproject;

--
-- Name: audit_voucher_changes(); Type: FUNCTION; Schema: vms; Owner: vmsproject
--

CREATE FUNCTION vms.audit_voucher_changes() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (TG_OP = 'UPDATE') THEN
        -- Auditer les changements de statut
        IF OLD.status_vouch IS DISTINCT FROM NEW.status_vouch THEN
            INSERT INTO voucher_audit (
                ref_voucher, no_voucher, ancien_statut, nouveau_statut, 
                action, details
            ) VALUES (
                NEW.ref_voucher, NEW.no_voucher, OLD.status_vouch, NEW.status_vouch,
                'UPDATE_STATUS', 
                'Statut changé de ' || COALESCE(OLD.status_vouch, 'NULL') || 
                ' à ' || COALESCE(NEW.status_vouch, 'NULL')
            );
        END IF;
        RETURN NEW;
        
    ELSIF (TG_OP = 'INSERT') THEN
        -- Auditer la création
        INSERT INTO voucher_audit (
            ref_voucher, no_voucher, ancien_statut, nouveau_statut, 
            action, details
        ) VALUES (
            NEW.ref_voucher, NEW.no_voucher, NULL, NEW.status_vouch,
            'INSERT', 
            'Nouveau voucher créé avec le statut ' || COALESCE(NEW.status_vouch, 'NULL')
        );
        RETURN NEW;
        
    ELSIF (TG_OP = 'DELETE') THEN
        -- Auditer la suppression
        INSERT INTO voucher_audit (
            ref_voucher, no_voucher, ancien_statut, nouveau_statut, 
            action, details
        ) VALUES (
            OLD.ref_voucher, OLD.no_voucher, OLD.status_vouch, NULL,
            'DELETE', 
            'Voucher supprimé avec le statut ' || COALESCE(OLD.status_vouch, 'NULL')
        );
        RETURN OLD;
    END IF;
    
    RETURN NULL;
END;
$$;


ALTER FUNCTION vms.audit_voucher_changes() OWNER TO vmsproject;

--
-- Name: batch_check_expired_vouchers(); Type: FUNCTION; Schema: vms; Owner: vmsproject
--

CREATE FUNCTION vms.batch_check_expired_vouchers() RETURNS TABLE(vouchers_expires integer, vouchers_ids integer[])
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_count INTEGER;
    v_ids INTEGER[];
BEGIN
    WITH updated AS (
        UPDATE voucher
        SET status_vouch = 'expire',
            updated_at = CURRENT_TIMESTAMP
        WHERE expire_date < CURRENT_TIMESTAMP
          AND status_vouch NOT IN ('expire', 'redime')
        RETURNING ref_voucher
    )
    SELECT COUNT(*), ARRAY_AGG(ref_voucher)
    INTO v_count, v_ids
    FROM updated;

    vouchers_expires := COALESCE(v_count, 0);
    vouchers_ids := COALESCE(v_ids, ARRAY[]::INTEGER[]);

    RETURN NEXT;
END;
$$;


ALTER FUNCTION vms.batch_check_expired_vouchers() OWNER TO vmsproject;

--
-- Name: fn_redem_log(); Type: FUNCTION; Schema: vms; Owner: vmsproject
--

CREATE FUNCTION vms.fn_redem_log() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_no_voucher VARCHAR(100);
BEGIN
    -- Récupérer le no_voucher associé (peut être NULL si ref_voucher est NULL)
    IF NEW.ref_voucher IS NOT NULL THEN
        SELECT no_voucher INTO v_no_voucher
        FROM vms.voucher
        WHERE ref_voucher = NEW.ref_voucher;
    ELSE
        v_no_voucher := NULL;
    END IF;

    INSERT INTO vms.redemption_logs (
        ref_voucher,
        no_voucher,
        magasin_id,
        redeemed_by,
        statut,
        motif_echec,
        log_date,
        details
    )
    VALUES (
        NEW.ref_voucher,
        v_no_voucher,
        NEW.magasin_id,
        NEW.redeemed_by,
        NEW.statut,                    -- 'success' ou 'failed'
        NEW.motif_echec,               -- NULL si succès
        COALESCE(NEW.date_redemption, CURRENT_TIMESTAMP),
        jsonb_build_object(
            'ref_redemption', NEW.ref_redemption,
            'source',         'trigger:redem_log_trigger'
        )
    );

    RETURN NEW;
END;
$$;


ALTER FUNCTION vms.fn_redem_log() OWNER TO vmsproject;

--
-- Name: FUNCTION fn_redem_log(); Type: COMMENT; Schema: vms; Owner: vmsproject
--

COMMENT ON FUNCTION vms.fn_redem_log() IS 'Fonction trigger : insère automatiquement un log dans vms.redemption_logs après chaque INSERT dans vms.redemption.';


--
-- Name: generate_vouchers_for_demande(integer); Type: FUNCTION; Schema: vms; Owner: vmsproject
--

CREATE FUNCTION vms.generate_vouchers_for_demande(p_demande_id integer) RETURNS TABLE(ref_voucher integer, no_voucher character varying, montant numeric, status_vouch vms.voucher_status)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_nb_voucher INTEGER;
    v_valeur_voucher NUMERIC(12,2);
    v_client_id INTEGER;
    v_duree INTEGER;
    v_issue_date TIMESTAMP;
    v_expire_date TIMESTAMP;
    v_qr_content TEXT;
    v_voucher_no VARCHAR(100);
    v_counter INTEGER;
    v_timestamp VARCHAR(20);
BEGIN
    SELECT d.nb_voucher,
           d.valeur_voucher,
           d.client_id,
           COALESCE(d.duree, 365)
    INTO v_nb_voucher,
         v_valeur_voucher,
         v_client_id,
         v_duree
    FROM vms.demande d
    WHERE d.ref_demande = p_demande_id
      AND d.statut = 'approuvee';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Demande non trouvée ou non approuvée: %', p_demande_id;
    END IF;

    v_issue_date  := CURRENT_TIMESTAMP;
    v_expire_date := v_issue_date + (v_duree || ' days')::INTERVAL;
    v_timestamp   := TO_CHAR(CURRENT_TIMESTAMP, 'YYYYMMDDHH24MISS');

    FOR v_counter IN 1..v_nb_voucher LOOP
        v_voucher_no := 'VCH-' || p_demande_id || '-' || v_timestamp || '-' || v_counter;
        v_qr_content := 'VMS|VOUCHER|' || v_voucher_no;

        INSERT INTO vms.voucher (
            no_voucher, montant, issue_date, expire_date,
            qr_code, status_vouch, client_id, ref_demande
        )
        VALUES (
            v_voucher_no, v_valeur_voucher, v_issue_date, v_expire_date,
            v_qr_content, 'issued', v_client_id, p_demande_id
        )
        RETURNING
            voucher.ref_voucher,
            voucher.no_voucher,
            voucher.montant,
            voucher.status_vouch
        INTO
            ref_voucher,
            no_voucher,
            montant,
            status_vouch;

        RETURN NEXT;
    END LOOP;

    UPDATE vms.demande
    SET status_demande = 'vouchers_generes'
    WHERE ref_demande = p_demande_id;

    RETURN;
END;
$$;


ALTER FUNCTION vms.generate_vouchers_for_demande(p_demande_id integer) OWNER TO vmsproject;

--
-- Name: log_login_attempt(); Type: FUNCTION; Schema: vms; Owner: vmsproject
--

CREATE FUNCTION vms.log_login_attempt() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO vms.login_logs (user_id, username, role, statut, message, created_at)
    VALUES (
        NEW.user_id,
        NEW.username,
        NEW.role,
        'succès',
        'Connexion réussie pour ' || NEW.username,
        NOW()
    );
    RETURN NEW;
END;
$$;


ALTER FUNCTION vms.log_login_attempt() OWNER TO vmsproject;

--
-- Name: update_expired_vouchers(); Type: FUNCTION; Schema: vms; Owner: vmsproject
--

CREATE FUNCTION vms.update_expired_vouchers() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- NEW.status_vouch vérifie que la ligne insérée/modifiée
    -- n'est pas déjà 'expired' pour éviter la récursion
    IF NEW.status_vouch = 'issued'
       AND NEW.expire_date IS NOT NULL
       AND NEW.expire_date < CURRENT_DATE THEN
        NEW.status_vouch := 'expired';
        NEW.updated_at   := CURRENT_TIMESTAMP;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION vms.update_expired_vouchers() OWNER TO vmsproject;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: permissions; Type: TABLE; Schema: public; Owner: vmsproject
--

CREATE TABLE public.permissions (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    module character varying(50),
    action character varying(50),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.permissions OWNER TO vmsproject;

--
-- Name: permissions_id_seq; Type: SEQUENCE; Schema: public; Owner: vmsproject
--

CREATE SEQUENCE public.permissions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.permissions_id_seq OWNER TO vmsproject;

--
-- Name: permissions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: vmsproject
--

ALTER SEQUENCE public.permissions_id_seq OWNED BY public.permissions.id;


--
-- Name: role_permissions; Type: TABLE; Schema: public; Owner: vmsproject
--

CREATE TABLE public.role_permissions (
    role_id integer NOT NULL,
    permission_id integer NOT NULL
);


ALTER TABLE public.role_permissions OWNER TO vmsproject;

--
-- Name: roles; Type: TABLE; Schema: public; Owner: vmsproject
--

CREATE TABLE public.roles (
    id integer NOT NULL,
    name character varying(50) NOT NULL,
    description text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    permissions text
);


ALTER TABLE public.roles OWNER TO vmsproject;

--
-- Name: roles_id_seq; Type: SEQUENCE; Schema: public; Owner: vmsproject
--

CREATE SEQUENCE public.roles_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.roles_id_seq OWNER TO vmsproject;

--
-- Name: roles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: vmsproject
--

ALTER SEQUENCE public.roles_id_seq OWNED BY public.roles.id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: vmsproject
--

CREATE TABLE public.users (
    id integer NOT NULL,
    username character varying(50) NOT NULL,
    password character varying(255) NOT NULL,
    email character varying(100) NOT NULL,
    full_name character varying(100),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    role_id integer
);


ALTER TABLE public.users OWNER TO vmsproject;

--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: vmsproject
--

CREATE SEQUENCE public.users_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.users_id_seq OWNER TO vmsproject;

--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: vmsproject
--

ALTER SEQUENCE public.users_id_seq OWNED BY public.users.id;


--
-- Name: voucher_usage; Type: TABLE; Schema: public; Owner: vmsproject
--

CREATE TABLE public.voucher_usage (
    id integer NOT NULL,
    voucher_id integer,
    user_id integer,
    reservation_id integer,
    used_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    discount_applied numeric(10,2)
);


ALTER TABLE public.voucher_usage OWNER TO vmsproject;

--
-- Name: voucher_usage_id_seq; Type: SEQUENCE; Schema: public; Owner: vmsproject
--

CREATE SEQUENCE public.voucher_usage_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.voucher_usage_id_seq OWNER TO vmsproject;

--
-- Name: voucher_usage_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: vmsproject
--

ALTER SEQUENCE public.voucher_usage_id_seq OWNED BY public.voucher_usage.id;


--
-- Name: vouchers; Type: TABLE; Schema: public; Owner: vmsproject
--

CREATE TABLE public.vouchers (
    id integer NOT NULL,
    code character varying(50) NOT NULL,
    description text,
    discount_type character varying(20),
    discount_value numeric(10,2) NOT NULL,
    max_usage integer DEFAULT 1,
    current_usage integer DEFAULT 0,
    valid_from timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    valid_until timestamp without time zone,
    is_active boolean DEFAULT true,
    created_by integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT vouchers_discount_type_check CHECK (((discount_type)::text = ANY ((ARRAY['PERCENTAGE'::character varying, 'FIXED_AMOUNT'::character varying])::text[])))
);


ALTER TABLE public.vouchers OWNER TO vmsproject;

--
-- Name: vouchers_id_seq; Type: SEQUENCE; Schema: public; Owner: vmsproject
--

CREATE SEQUENCE public.vouchers_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.vouchers_id_seq OWNER TO vmsproject;

--
-- Name: vouchers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: vmsproject
--

ALTER SEQUENCE public.vouchers_id_seq OWNED BY public.vouchers.id;


--
-- Name: client; Type: TABLE; Schema: vms; Owner: vmsproject
--

CREATE TABLE vms.client (
    ref_client integer NOT NULL,
    nom_client character varying(150) NOT NULL,
    email character varying(254),
    adresse character varying(255),
    company character varying(255),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE vms.client OWNER TO vmsproject;

--
-- Name: client_ref_client_seq; Type: SEQUENCE; Schema: vms; Owner: vmsproject
--

CREATE SEQUENCE vms.client_ref_client_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vms.client_ref_client_seq OWNER TO vmsproject;

--
-- Name: client_ref_client_seq; Type: SEQUENCE OWNED BY; Schema: vms; Owner: vmsproject
--

ALTER SEQUENCE vms.client_ref_client_seq OWNED BY vms.client.ref_client;


--
-- Name: demande; Type: TABLE; Schema: vms; Owner: vmsproject
--

CREATE TABLE vms.demande (
    ref_demande integer NOT NULL,
    client_id integer NOT NULL,
    date_creation timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    nb_voucher integer DEFAULT 0,
    valeur_voucher numeric(12,2) DEFAULT 0.00,
    statut vms.demande_status DEFAULT 'initiee'::vms.demande_status,
    date_payement timestamp without time zone,
    date_approbation timestamp without time zone,
    duree integer,
    expire_date date,
    status_demande character varying(80),
    initiated_by integer,
    approved_by integer,
    paid_by integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE vms.demande OWNER TO vmsproject;

--
-- Name: demande_ref_demande_seq; Type: SEQUENCE; Schema: vms; Owner: vmsproject
--

CREATE SEQUENCE vms.demande_ref_demande_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vms.demande_ref_demande_seq OWNER TO vmsproject;

--
-- Name: demande_ref_demande_seq; Type: SEQUENCE OWNED BY; Schema: vms; Owner: vmsproject
--

ALTER SEQUENCE vms.demande_ref_demande_seq OWNED BY vms.demande.ref_demande;


--
-- Name: login_logs; Type: TABLE; Schema: vms; Owner: vmsproject
--

CREATE TABLE vms.login_logs (
    log_id integer NOT NULL,
    user_id integer,
    username character varying(100),
    role character varying(50),
    statut character varying(10),
    message text,
    created_at timestamp without time zone DEFAULT now()
);


ALTER TABLE vms.login_logs OWNER TO vmsproject;

--
-- Name: login_logs_log_id_seq; Type: SEQUENCE; Schema: vms; Owner: vmsproject
--

CREATE SEQUENCE vms.login_logs_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vms.login_logs_log_id_seq OWNER TO vmsproject;

--
-- Name: login_logs_log_id_seq; Type: SEQUENCE OWNED BY; Schema: vms; Owner: vmsproject
--

ALTER SEQUENCE vms.login_logs_log_id_seq OWNED BY vms.login_logs.log_id;


--
-- Name: magasin; Type: TABLE; Schema: vms; Owner: vmsproject
--

CREATE TABLE vms.magasin (
    magasin_id integer NOT NULL,
    nom character varying(150) NOT NULL,
    attribute1 character varying(255),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE vms.magasin OWNER TO vmsproject;

--
-- Name: magasin_magasin_id_seq; Type: SEQUENCE; Schema: vms; Owner: vmsproject
--

CREATE SEQUENCE vms.magasin_magasin_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vms.magasin_magasin_id_seq OWNER TO vmsproject;

--
-- Name: magasin_magasin_id_seq; Type: SEQUENCE OWNED BY; Schema: vms; Owner: vmsproject
--

ALTER SEQUENCE vms.magasin_magasin_id_seq OWNED BY vms.magasin.magasin_id;


--
-- Name: redemption; Type: TABLE; Schema: vms; Owner: vmsproject
--

CREATE TABLE vms.redemption (
    ref_redemption integer NOT NULL,
    ref_voucher integer NOT NULL,
    magasin_id integer NOT NULL,
    redeemed_by integer NOT NULL,
    date_redemption timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    statut character varying(20) DEFAULT 'success'::character varying,
    motif_echec text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE vms.redemption OWNER TO vmsproject;

--
-- Name: redemption_logs; Type: TABLE; Schema: vms; Owner: vmsproject
--

CREATE TABLE vms.redemption_logs (
    log_id integer NOT NULL,
    ref_voucher integer,
    no_voucher character varying(100),
    magasin_id integer,
    redeemed_by integer,
    statut character varying(20) NOT NULL,
    motif_echec text,
    log_date timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    details jsonb,
    CONSTRAINT redemption_logs_statut_check CHECK (((statut)::text = ANY ((ARRAY['success'::character varying, 'failed'::character varying])::text[])))
);


ALTER TABLE vms.redemption_logs OWNER TO vmsproject;

--
-- Name: TABLE redemption_logs; Type: COMMENT; Schema: vms; Owner: vmsproject
--

COMMENT ON TABLE vms.redemption_logs IS 'Logs automatiques de toutes les tentatives de rédemption (succès et échecs). Alimenté par le trigger redem_log_trigger.';


--
-- Name: COLUMN redemption_logs.no_voucher; Type: COMMENT; Schema: vms; Owner: vmsproject
--

COMMENT ON COLUMN vms.redemption_logs.no_voucher IS 'Copie du code voucher au moment de la tentative (conservation historique).';


--
-- Name: COLUMN redemption_logs.statut; Type: COMMENT; Schema: vms; Owner: vmsproject
--

COMMENT ON COLUMN vms.redemption_logs.statut IS '''success'' = rédemption réussie, ''failed'' = tentative échouée';


--
-- Name: COLUMN redemption_logs.motif_echec; Type: COMMENT; Schema: vms; Owner: vmsproject
--

COMMENT ON COLUMN vms.redemption_logs.motif_echec IS 'Raison de l''échec (NOT_FOUND, EXPIRED, ALREADY_REDEEMED, INVALID_STATUS…). NULL si succès.';


--
-- Name: redemption_logs_log_id_seq; Type: SEQUENCE; Schema: vms; Owner: vmsproject
--

CREATE SEQUENCE vms.redemption_logs_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vms.redemption_logs_log_id_seq OWNER TO vmsproject;

--
-- Name: redemption_logs_log_id_seq; Type: SEQUENCE OWNED BY; Schema: vms; Owner: vmsproject
--

ALTER SEQUENCE vms.redemption_logs_log_id_seq OWNED BY vms.redemption_logs.log_id;


--
-- Name: redemption_ref_redemption_seq; Type: SEQUENCE; Schema: vms; Owner: vmsproject
--

CREATE SEQUENCE vms.redemption_ref_redemption_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vms.redemption_ref_redemption_seq OWNER TO vmsproject;

--
-- Name: redemption_ref_redemption_seq; Type: SEQUENCE OWNED BY; Schema: vms; Owner: vmsproject
--

ALTER SEQUENCE vms.redemption_ref_redemption_seq OWNED BY vms.redemption.ref_redemption;


--
-- Name: user_permissions; Type: TABLE; Schema: vms; Owner: vmsproject
--

CREATE TABLE vms.user_permissions (
    permission_id integer NOT NULL,
    user_id integer NOT NULL,
    menu_clients boolean DEFAULT false NOT NULL,
    menu_users boolean DEFAULT false NOT NULL,
    menu_magasins boolean DEFAULT false NOT NULL,
    menu_demandes boolean DEFAULT false NOT NULL,
    menu_vouchers boolean DEFAULT false NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE vms.user_permissions OWNER TO vmsproject;

--
-- Name: user_permissions_permission_id_seq; Type: SEQUENCE; Schema: vms; Owner: vmsproject
--

CREATE SEQUENCE vms.user_permissions_permission_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vms.user_permissions_permission_id_seq OWNER TO vmsproject;

--
-- Name: user_permissions_permission_id_seq; Type: SEQUENCE OWNED BY; Schema: vms; Owner: vmsproject
--

ALTER SEQUENCE vms.user_permissions_permission_id_seq OWNED BY vms.user_permissions.permission_id;


--
-- Name: users; Type: TABLE; Schema: vms; Owner: vmsproject
--

CREATE TABLE vms.users (
    user_id integer NOT NULL,
    username character varying(100) NOT NULL,
    nom character varying(100),
    prenom character varying(100),
    role vms.user_role DEFAULT 'agent'::vms.user_role,
    password_hash text,
    ddl timestamp without time zone,
    email character varying(254),
    titre character varying(100),
    statut vms.user_status DEFAULT 'active'::vms.user_status,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE vms.users OWNER TO vmsproject;

--
-- Name: users_user_id_seq; Type: SEQUENCE; Schema: vms; Owner: vmsproject
--

CREATE SEQUENCE vms.users_user_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vms.users_user_id_seq OWNER TO vmsproject;

--
-- Name: users_user_id_seq; Type: SEQUENCE OWNED BY; Schema: vms; Owner: vmsproject
--

ALTER SEQUENCE vms.users_user_id_seq OWNED BY vms.users.user_id;


--
-- Name: voucher; Type: TABLE; Schema: vms; Owner: vmsproject
--

CREATE TABLE vms.voucher (
    ref_voucher integer NOT NULL,
    no_voucher character varying(100) NOT NULL,
    montant numeric(12,2) DEFAULT 0.00 NOT NULL,
    issue_date timestamp without time zone,
    expire_date timestamp without time zone,
    qr_code text,
    status_vouch vms.voucher_status DEFAULT 'draft'::vms.voucher_status,
    client_id integer,
    ref_demande integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE vms.voucher OWNER TO vmsproject;

--
-- Name: voucher_action_log; Type: TABLE; Schema: vms; Owner: vmsproject
--

CREATE TABLE vms.voucher_action_log (
    action_id integer NOT NULL,
    voucher_id integer NOT NULL,
    action character varying(80) NOT NULL,
    performed_by integer,
    performed_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    details text
);


ALTER TABLE vms.voucher_action_log OWNER TO vmsproject;

--
-- Name: voucher_action_log_action_id_seq; Type: SEQUENCE; Schema: vms; Owner: vmsproject
--

CREATE SEQUENCE vms.voucher_action_log_action_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vms.voucher_action_log_action_id_seq OWNER TO vmsproject;

--
-- Name: voucher_action_log_action_id_seq; Type: SEQUENCE OWNED BY; Schema: vms; Owner: vmsproject
--

ALTER SEQUENCE vms.voucher_action_log_action_id_seq OWNED BY vms.voucher_action_log.action_id;


--
-- Name: voucher_audit; Type: TABLE; Schema: vms; Owner: vmsproject
--

CREATE TABLE vms.voucher_audit (
    audit_id integer NOT NULL,
    ref_voucher integer NOT NULL,
    no_voucher character varying(100),
    ancien_statut character varying(50),
    nouveau_statut character varying(50),
    action character varying(50),
    user_id integer,
    audit_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    ip_address character varying(50),
    details text
);


ALTER TABLE vms.voucher_audit OWNER TO vmsproject;

--
-- Name: voucher_audit_audit_id_seq; Type: SEQUENCE; Schema: vms; Owner: vmsproject
--

CREATE SEQUENCE vms.voucher_audit_audit_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vms.voucher_audit_audit_id_seq OWNER TO vmsproject;

--
-- Name: voucher_audit_audit_id_seq; Type: SEQUENCE OWNED BY; Schema: vms; Owner: vmsproject
--

ALTER SEQUENCE vms.voucher_audit_audit_id_seq OWNED BY vms.voucher_audit.audit_id;


--
-- Name: voucher_ref_voucher_seq; Type: SEQUENCE; Schema: vms; Owner: vmsproject
--

CREATE SEQUENCE vms.voucher_ref_voucher_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE vms.voucher_ref_voucher_seq OWNER TO vmsproject;

--
-- Name: voucher_ref_voucher_seq; Type: SEQUENCE OWNED BY; Schema: vms; Owner: vmsproject
--

ALTER SEQUENCE vms.voucher_ref_voucher_seq OWNED BY vms.voucher.ref_voucher;


--
-- Name: permissions id; Type: DEFAULT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.permissions ALTER COLUMN id SET DEFAULT nextval('public.permissions_id_seq'::regclass);


--
-- Name: roles id; Type: DEFAULT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.roles ALTER COLUMN id SET DEFAULT nextval('public.roles_id_seq'::regclass);


--
-- Name: users id; Type: DEFAULT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.users ALTER COLUMN id SET DEFAULT nextval('public.users_id_seq'::regclass);


--
-- Name: voucher_usage id; Type: DEFAULT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.voucher_usage ALTER COLUMN id SET DEFAULT nextval('public.voucher_usage_id_seq'::regclass);


--
-- Name: vouchers id; Type: DEFAULT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.vouchers ALTER COLUMN id SET DEFAULT nextval('public.vouchers_id_seq'::regclass);


--
-- Name: client ref_client; Type: DEFAULT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.client ALTER COLUMN ref_client SET DEFAULT nextval('vms.client_ref_client_seq'::regclass);


--
-- Name: demande ref_demande; Type: DEFAULT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.demande ALTER COLUMN ref_demande SET DEFAULT nextval('vms.demande_ref_demande_seq'::regclass);


--
-- Name: login_logs log_id; Type: DEFAULT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.login_logs ALTER COLUMN log_id SET DEFAULT nextval('vms.login_logs_log_id_seq'::regclass);


--
-- Name: magasin magasin_id; Type: DEFAULT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.magasin ALTER COLUMN magasin_id SET DEFAULT nextval('vms.magasin_magasin_id_seq'::regclass);


--
-- Name: redemption ref_redemption; Type: DEFAULT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.redemption ALTER COLUMN ref_redemption SET DEFAULT nextval('vms.redemption_ref_redemption_seq'::regclass);


--
-- Name: redemption_logs log_id; Type: DEFAULT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.redemption_logs ALTER COLUMN log_id SET DEFAULT nextval('vms.redemption_logs_log_id_seq'::regclass);


--
-- Name: user_permissions permission_id; Type: DEFAULT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.user_permissions ALTER COLUMN permission_id SET DEFAULT nextval('vms.user_permissions_permission_id_seq'::regclass);


--
-- Name: users user_id; Type: DEFAULT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.users ALTER COLUMN user_id SET DEFAULT nextval('vms.users_user_id_seq'::regclass);


--
-- Name: voucher ref_voucher; Type: DEFAULT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.voucher ALTER COLUMN ref_voucher SET DEFAULT nextval('vms.voucher_ref_voucher_seq'::regclass);


--
-- Name: voucher_action_log action_id; Type: DEFAULT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.voucher_action_log ALTER COLUMN action_id SET DEFAULT nextval('vms.voucher_action_log_action_id_seq'::regclass);


--
-- Name: voucher_audit audit_id; Type: DEFAULT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.voucher_audit ALTER COLUMN audit_id SET DEFAULT nextval('vms.voucher_audit_audit_id_seq'::regclass);


--
-- Data for Name: permissions; Type: TABLE DATA; Schema: public; Owner: vmsproject
--

COPY public.permissions (id, name, description, module, action, created_at) FROM stdin;
1	users.create	Créer des utilisateurs	users	create	2025-11-26 05:22:59.954792
2	users.read	Voir les utilisateurs	users	read	2025-11-26 05:22:59.954792
3	users.update	Modifier les utilisateurs	users	update	2025-11-26 05:22:59.954792
4	users.delete	Supprimer les utilisateurs	users	delete	2025-11-26 05:22:59.954792
5	vehicles.create	Ajouter des véhicules	vehicles	create	2025-11-26 05:22:59.954792
6	vehicles.read	Voir les véhicules	vehicles	read	2025-11-26 05:22:59.954792
7	vehicles.update	Modifier les véhicules	vehicles	update	2025-11-26 05:22:59.954792
8	vehicles.delete	Supprimer les véhicules	vehicles	delete	2025-11-26 05:22:59.954792
9	reservations.create	Créer des réservations	reservations	create	2025-11-26 05:22:59.954792
10	reservations.read	Voir les réservations	reservations	read	2025-11-26 05:22:59.954792
11	reservations.update	Modifier les réservations	reservations	update	2025-11-26 05:22:59.954792
12	reservations.delete	Annuler les réservations	reservations	delete	2025-11-26 05:22:59.954792
13	vouchers.create	Créer des vouchers	vouchers	create	2025-11-26 05:22:59.954792
14	vouchers.read	Voir les vouchers	vouchers	read	2025-11-26 05:22:59.954792
15	vouchers.update	Modifier les vouchers	vouchers	update	2025-11-26 05:22:59.954792
16	vouchers.delete	Supprimer les vouchers	vouchers	delete	2025-11-26 05:22:59.954792
17	vouchers.use	Utiliser des vouchers	vouchers	use	2025-11-26 05:22:59.954792
18	vouchers.view_all	Voir tous les vouchers (inactifs inclus)	vouchers	admin	2025-11-26 05:22:59.954792
19	vouchers.reports	Voir statistiques vouchers	vouchers	report	2025-11-26 05:22:59.954792
20	reports.view	Voir les rapports	reports	read	2025-11-26 05:22:59.954792
21	reports.export	Exporter les rapports	reports	export	2025-11-26 05:22:59.954792
22	settings.manage	Gérer paramètres système	settings	update	2025-11-26 05:22:59.954792
\.


--
-- Data for Name: role_permissions; Type: TABLE DATA; Schema: public; Owner: vmsproject
--

COPY public.role_permissions (role_id, permission_id) FROM stdin;
1	1
1	2
1	3
1	4
1	5
1	6
1	7
1	8
1	9
1	10
1	11
1	12
1	13
1	14
1	15
1	16
1	17
1	18
1	19
1	20
1	21
1	22
2	2
2	5
2	6
2	7
2	8
2	9
2	10
2	11
2	12
2	13
2	14
2	15
2	16
2	17
2	18
2	19
2	20
2	21
3	6
3	9
3	10
3	14
3	17
4	2
4	6
4	10
4	14
4	20
\.


--
-- Data for Name: roles; Type: TABLE DATA; Schema: public; Owner: vmsproject
--

COPY public.roles (id, name, description, created_at, permissions) FROM stdin;
3	USER	Utilisateur standard	2025-11-26 05:22:59.954792	\N
1	ADMIN	Administrateur avec tous les droits	2025-11-26 05:22:59.954792	ALL_ACCESS,MANAGE_USERS,MANAGE_VOUCHERS,VIEW_REPORTS,DELETE_VOUCHERS
2	MANAGER	Gestionnaire de flotte et vouchers	2025-11-26 05:22:59.954792	MANAGE_VOUCHERS,VIEW_REPORTS,EDIT_CLIENTS
11	AGENT	\N	2025-11-26 06:24:48.804485	CREATE_VOUCHERS,VIEW_VOUCHERS,SEARCH_CLIENTS
4	VIEWER	Lecture seule	2025-11-26 05:22:59.954792	VIEW_VOUCHERS,READ_ONLY
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: vmsproject
--

COPY public.users (id, username, password, email, full_name, created_at, updated_at, role_id) FROM stdin;
3	user	user123	user@vms.com	User Test	2025-11-26 05:22:59.954792	2025-11-26 05:22:59.954792	3
1	admin	admin123	admin@vms.com	Administrateur Système	2025-11-26 05:12:21.38275	2025-11-26 05:12:21.38275	1
2	manager	manager123	manager@vms.com	Manager Principal	2025-11-26 05:22:59.954792	2025-11-26 05:22:59.954792	2
11	agent	agent123	agent@vms.com	Agent Commercial	2025-11-26 06:24:48.804485	2025-11-26 06:24:48.804485	11
4	viewer	viewer123	viewer@vms.com	Visualisateur	2025-11-26 05:22:59.954792	2025-11-26 05:22:59.954792	4
\.


--
-- Data for Name: voucher_usage; Type: TABLE DATA; Schema: public; Owner: vmsproject
--

COPY public.voucher_usage (id, voucher_id, user_id, reservation_id, used_at, discount_applied) FROM stdin;
\.


--
-- Data for Name: vouchers; Type: TABLE DATA; Schema: public; Owner: vmsproject
--

COPY public.vouchers (id, code, description, discount_type, discount_value, max_usage, current_usage, valid_from, valid_until, is_active, created_by, created_at, updated_at) FROM stdin;
1	WELCOME2025	Voucher bienvenue 10%	PERCENTAGE	10.00	100	0	2025-11-26 05:22:59.954792	\N	t	1	2025-11-26 05:22:59.954792	2025-11-26 05:22:59.954792
2	FIRST50	Première réservation -50€	FIXED_AMOUNT	50.00	50	0	2025-11-26 05:22:59.954792	\N	t	1	2025-11-26 05:22:59.954792	2025-11-26 05:22:59.954792
3	VIP20	Réduction VIP 20%	PERCENTAGE	20.00	10	0	2025-11-26 05:22:59.954792	\N	t	1	2025-11-26 05:22:59.954792	2025-11-26 05:22:59.954792
4	SUMMER15	Promo été 15%	PERCENTAGE	15.00	200	0	2025-11-26 05:22:59.954792	\N	t	1	2025-11-26 05:22:59.954792	2025-11-26 05:22:59.954792
\.


--
-- Data for Name: client; Type: TABLE DATA; Schema: vms; Owner: vmsproject
--

COPY vms.client (ref_client, nom_client, email, adresse, company, created_at, updated_at) FROM stdin;
2	Thomas	ford@gmail.com	Rosehill	FORD	2025-11-10 10:00:22.704901	2025-11-10 10:00:22.704901
3	Anwell	anwell@gmail.com	Quatres Bornes	Winners	2025-11-10 10:36:39.779866	2025-11-10 10:36:39.779866
5	Yussuf	mcci@gmail.com	EBENE	MCCI	2025-11-12 08:14:07.808411	2025-11-12 08:14:07.808411
6	Anwell	toyota@gmail.com	Rosehill	TOYOTA	2025-11-17 10:05:44.781368	2025-11-17 10:05:44.781368
9	Mahoney	kia@gmail.com	Ebene	KIA	2025-11-17 10:26:25.889431	2025-11-17 10:26:25.889431
10	Yussuf	yussuf@gmail.com	ROSEHILL	APPLE	2025-11-26 08:52:29.782225	2025-11-26 08:52:29.782225
14	Marcel RAFA	marcel@gmail.com	4 Bornes	Gravity	2025-12-08 08:39:09.256826	2025-12-08 08:39:09.256826
12	Francky Anthony Marcel	lacoste@gmail.com	ROSEHILL	LACOSTE	2025-12-03 08:18:34.524666	2025-12-03 08:18:34.524666
16	MAE	mae@gmail.com	ROSEHILL	TESLA	2026-02-20 19:26:47.713792	2026-02-20 19:26:47.713792
17	NICOLAS Tesla	nicolas@gmail.com	Rosehill	TESLA	2026-03-12 20:35:43.960566	2026-03-12 20:35:43.960566
19	ECONA Marta	econa@gmail.con	Rosehill	Econa	2026-03-12 23:42:06.735488	2026-03-12 23:42:06.735488
20	BTS SIO	btssio@gmail.com	CUREPIPE	BTS	2026-04-13 11:00:26.192857	2026-04-13 11:00:26.192857
21	Kazuya	tekken@gmail.com	Kazama	YROF	2026-04-21 00:04:29.488047	2026-04-21 00:04:29.488047
\.


--
-- Data for Name: demande; Type: TABLE DATA; Schema: vms; Owner: vmsproject
--

COPY vms.demande (ref_demande, client_id, date_creation, nb_voucher, valeur_voucher, statut, date_payement, date_approbation, duree, expire_date, status_demande, initiated_by, approved_by, paid_by, created_at, updated_at) FROM stdin;
17	21	2026-04-21 00:09:44.519773	45	5000.00	approuvee	2026-04-21 00:11:01.552846	2026-04-21 00:11:12.23778	60	\N	vouchers_generes	5	5	5	2026-04-21 00:09:44.519773	2026-04-21 00:09:44.519773
15	20	2026-04-13 11:00:28.296472	5	5000.00	initiee	\N	\N	100	2026-07-22	Demande en attente de validation	\N	\N	\N	2026-04-13 11:00:28.296472	2026-04-13 11:00:28.296472
\.


--
-- Data for Name: login_logs; Type: TABLE DATA; Schema: vms; Owner: vmsproject
--

COPY vms.login_logs (log_id, user_id, username, role, statut, message, created_at) FROM stdin;
1	5	admin	admin	succès	Connexion réussie pour admin	2026-03-30 11:47:02.820168
2	5	admin	admin	succès	Connexion réussie	2026-03-30 11:47:04.755235
3	\N	admin	\N	échec	Mot de passe incorrect	2026-03-30 11:49:04.155751
4	5	admin	admin	succès	Connexion réussie pour admin	2026-03-30 12:06:03.850915
5	5	admin	admin	succès	Connexion réussie pour admin	2026-03-30 12:07:17.830838
6	5	admin	admin	succès	Connexion réussie	2026-03-30 12:07:19.655778
7	5	admin	admin	succès	Connexion réussie pour admin	2026-03-30 12:22:07.603399
8	5	admin	admin	succès	Connexion réussie	2026-03-30 12:22:09.411231
9	\N	admin	\N	échec	Mot de passe incorrect	2026-03-30 12:22:28.55113
10	5	admin	admin	succès	Connexion réussie pour admin	2026-03-30 12:34:29.871937
11	5	admin	admin	succès	Connexion réussie	2026-03-30 12:34:31.762905
12	5	admin	admin	succès	Connexion réussie pour admin	2026-04-13 10:20:22.575679
13	5	admin	admin	succès	Connexion réussie pour admin	2026-04-13 11:01:21.377277
14	5	admin	admin	succès	Connexion réussie pour admin	2026-04-13 14:13:52.631525
15	5	admin	admin	succès	Connexion réussie pour admin	2026-04-13 17:12:31.113743
16	5	admin	admin	succès	Connexion réussie pour admin	2026-04-15 16:16:14.707901
17	5	admin	admin	succès	Connexion réussie pour admin	2026-04-15 16:49:45.133007
18	5	admin	admin	succès	Connexion réussie pour admin	2026-04-15 16:50:37.763675
19	5	admin	admin	succès	Connexion réussie pour admin	2026-04-15 17:01:38.643037
20	5	admin	admin	succès	Connexion réussie pour admin	2026-04-15 17:05:39.39237
21	5	admin	admin	succès	Connexion réussie pour admin	2026-04-15 17:08:06.465447
22	5	admin	admin	succès	Connexion réussie pour admin	2026-04-16 18:17:24.696059
23	5	admin	admin	succès	Connexion réussie pour admin	2026-04-17 13:40:37.149747
24	5	admin	admin	succès	Connexion réussie pour admin	2026-04-17 14:57:36.079426
25	5	admin	admin	succès	Connexion réussie pour admin	2026-04-19 11:27:33.527377
26	5	admin	admin	succès	Connexion réussie pour admin	2026-04-20 08:47:35.268388
27	5	admin	admin	succès	Connexion réussie pour admin	2026-04-20 09:01:52.815069
28	5	admin	admin	succès	Connexion réussie pour admin	2026-04-20 09:54:58.178747
29	5	admin	admin	succès	Connexion réussie pour admin	2026-04-20 14:05:12.579255
30	5	admin	admin	succès	Connexion réussie pour admin	2026-04-20 23:57:21.161915
31	6	manager	manager	succès	Connexion réussie pour manager	2026-04-21 08:23:03.54248
32	5	admin	admin	succès	Connexion réussie pour admin	2026-04-21 08:24:36.678336
33	7	approbateur	agent	succès	Connexion réussie pour approbateur	2026-04-21 08:33:54.747014
34	5	admin	admin	succès	Connexion réussie pour admin	2026-04-21 08:54:56.49196
\.


--
-- Data for Name: magasin; Type: TABLE DATA; Schema: vms; Owner: vmsproject
--

COPY vms.magasin (magasin_id, nom, attribute1, created_at) FROM stdin;
1	INTERMART	ROSEHILL	2025-11-26 09:26:54.703252
3	Feu de bois	Tribecca	2025-12-08 08:41:31.106008
4	MonTebelo	Paille	2026-04-21 00:08:09.427932
\.


--
-- Data for Name: redemption; Type: TABLE DATA; Schema: vms; Owner: vmsproject
--

COPY vms.redemption (ref_redemption, ref_voucher, magasin_id, redeemed_by, date_redemption, statut, motif_echec, created_at) FROM stdin;
5	58	3	7	2026-03-30 11:04:54.525572	success	\N	2026-03-30 11:04:54.525572
6	38	3	7	2026-03-30 11:06:49.565277	success	\N	2026-03-30 11:06:49.565277
7	38	3	7	2026-03-30 11:09:07.769083	failed	ALREADY_REDEEMED : bon déjà utilisé	2026-03-30 11:09:07.769083
8	47	3	7	2026-03-30 11:19:54.833146	success	\N	2026-03-30 11:19:54.833146
\.


--
-- Data for Name: redemption_logs; Type: TABLE DATA; Schema: vms; Owner: vmsproject
--

COPY vms.redemption_logs (log_id, ref_voucher, no_voucher, magasin_id, redeemed_by, statut, motif_echec, log_date, details) FROM stdin;
4	58	VCH-10-20260330104100-1	3	7	success	\N	2026-03-30 07:04:54.525572+00	{"source": "trigger:redem_log_trigger", "ref_redemption": 5}
5	38	VCH-4-20260220180728-1	3	7	success	\N	2026-03-30 07:06:49.565277+00	{"source": "trigger:redem_log_trigger", "ref_redemption": 6}
6	38	VCH-4-20260220180728-1	3	7	failed	ALREADY_REDEEMED : bon déjà utilisé	2026-03-30 07:09:07.769083+00	{"source": "trigger:redem_log_trigger", "ref_redemption": 7}
7	47	VCH-4-20260220180728-10	3	7	success	\N	2026-03-30 07:19:54.833146+00	{"source": "trigger:redem_log_trigger", "ref_redemption": 8}
\.


--
-- Data for Name: user_permissions; Type: TABLE DATA; Schema: vms; Owner: vmsproject
--

COPY vms.user_permissions (permission_id, user_id, menu_clients, menu_users, menu_magasins, menu_demandes, menu_vouchers, created_at, updated_at) FROM stdin;
1	5	t	t	t	t	t	2026-03-13 05:43:45.655737	2026-03-13 05:43:45.655737
2	6	t	f	t	t	t	2026-03-13 05:43:45.655737	2026-03-13 05:43:45.655737
3	7	f	f	f	t	t	2026-03-13 05:43:45.655737	2026-04-21 08:32:47.467068
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: vms; Owner: vmsproject
--

COPY vms.users (user_id, username, nom, prenom, role, password_hash, ddl, email, titre, statut, created_at, updated_at) FROM stdin;
6	manager	Manager	Général	manager	866485796cfa8d7c0cf7111640205b83076433547577511d81f8030ae99ecea5	2026-04-21 08:23:03.54248	manager@vms.local	Manager	active	2026-02-09 09:03:55.481171	2026-02-09 09:03:55.481171
7	approbateur	des Demandes	Approbation	agent	dd4818acb612260667ff6af299bd268d1a894dddb7d4ec6d2ab8222719ea3bec	2026-04-21 08:33:54.747014	agent@vms.local	Approbateur	active	2026-02-09 09:04:11.831905	2026-04-21 08:32:45.527945
5	admin	Admin	Système	admin	240be518fabd2724ddb6f04eeb1da5967448d7e831c08c8fa822809f74c720a9	2026-04-21 08:54:56.49196	admin@vms.local	Administrateur Système	active	2026-02-09 09:03:37.18841	2026-02-09 09:03:37.18841
\.


--
-- Data for Name: voucher; Type: TABLE DATA; Schema: vms; Owner: vmsproject
--

COPY vms.voucher (ref_voucher, no_voucher, montant, issue_date, expire_date, qr_code, status_vouch, client_id, ref_demande, created_at, updated_at) FROM stdin;
48	VCH-14-20260312234832-1	500.00	2026-03-12 23:48:32.759972	2026-06-20 23:48:32.759972	VMS|VOUCHER|VCH-14-20260312234832-1	issued	19	\N	2026-03-12 23:48:32.759972	2026-03-12 23:48:32.759972
49	VCH-14-20260312234832-2	500.00	2026-03-12 23:48:32.759972	2026-06-20 23:48:32.759972	VMS|VOUCHER|VCH-14-20260312234832-2	issued	19	\N	2026-03-12 23:48:32.759972	2026-03-12 23:48:32.759972
50	VCH-14-20260312234832-3	500.00	2026-03-12 23:48:32.759972	2026-06-20 23:48:32.759972	VMS|VOUCHER|VCH-14-20260312234832-3	issued	19	\N	2026-03-12 23:48:32.759972	2026-03-12 23:48:32.759972
51	VCH-14-20260312234832-4	500.00	2026-03-12 23:48:32.759972	2026-06-20 23:48:32.759972	VMS|VOUCHER|VCH-14-20260312234832-4	issued	19	\N	2026-03-12 23:48:32.759972	2026-03-12 23:48:32.759972
39	VCH-4-20260220180728-2	1000.00	2026-02-20 18:07:28.236601	2026-05-31 18:07:28.236601	VMS|VOUCHER|VCH-4-20260220180728-2	issued	9	\N	2026-02-20 18:07:28.236601	2026-02-20 18:07:28.236601
4	VCH-8-20260127193137-1	500.00	2026-01-27 19:31:37.24035	2026-04-27 19:31:37.24035	VMS|VOUCHER|VCH-8-20260127193137-1	issued	14	\N	2026-01-27 19:31:37.24035	2026-01-27 19:31:37.24035
5	VCH-8-20260127193137-2	500.00	2026-01-27 19:31:37.24035	2026-04-27 19:31:37.24035	VMS|VOUCHER|VCH-8-20260127193137-2	issued	14	\N	2026-01-27 19:31:37.24035	2026-01-27 19:31:37.24035
6	VCH-8-20260127193137-3	500.00	2026-01-27 19:31:37.24035	2026-04-27 19:31:37.24035	VMS|VOUCHER|VCH-8-20260127193137-3	issued	14	\N	2026-01-27 19:31:37.24035	2026-01-27 19:31:37.24035
7	VCH-8-20260127193137-4	500.00	2026-01-27 19:31:37.24035	2026-04-27 19:31:37.24035	VMS|VOUCHER|VCH-8-20260127193137-4	issued	14	\N	2026-01-27 19:31:37.24035	2026-01-27 19:31:37.24035
8	VCH-8-20260127193137-5	500.00	2026-01-27 19:31:37.24035	2026-04-27 19:31:37.24035	VMS|VOUCHER|VCH-8-20260127193137-5	issued	14	\N	2026-01-27 19:31:37.24035	2026-01-27 19:31:37.24035
9	VCH-8-20260127193137-6	500.00	2026-01-27 19:31:37.24035	2026-04-27 19:31:37.24035	VMS|VOUCHER|VCH-8-20260127193137-6	issued	14	\N	2026-01-27 19:31:37.24035	2026-01-27 19:31:37.24035
10	VCH-8-20260127193137-7	500.00	2026-01-27 19:31:37.24035	2026-04-27 19:31:37.24035	VMS|VOUCHER|VCH-8-20260127193137-7	issued	14	\N	2026-01-27 19:31:37.24035	2026-01-27 19:31:37.24035
11	VCH-8-20260127193137-8	500.00	2026-01-27 19:31:37.24035	2026-04-27 19:31:37.24035	VMS|VOUCHER|VCH-8-20260127193137-8	issued	14	\N	2026-01-27 19:31:37.24035	2026-01-27 19:31:37.24035
12	VCH-8-20260127193137-9	500.00	2026-01-27 19:31:37.24035	2026-04-27 19:31:37.24035	VMS|VOUCHER|VCH-8-20260127193137-9	issued	14	\N	2026-01-27 19:31:37.24035	2026-01-27 19:31:37.24035
13	VCH-8-20260127193137-10	500.00	2026-01-27 19:31:37.24035	2026-04-27 19:31:37.24035	VMS|VOUCHER|VCH-8-20260127193137-10	issued	14	\N	2026-01-27 19:31:37.24035	2026-01-27 19:31:37.24035
68	VCH-12-20260330104936-1	1000.00	2026-03-30 10:49:36.499757	2026-04-29 10:49:36.499757	VMS|VOUCHER|VCH-12-20260330104936-1	issued	16	\N	2026-03-30 10:49:36.499757	2026-03-30 10:49:36.499757
69	VCH-12-20260330104936-2	1000.00	2026-03-30 10:49:36.499757	2026-04-29 10:49:36.499757	VMS|VOUCHER|VCH-12-20260330104936-2	issued	16	\N	2026-03-30 10:49:36.499757	2026-03-30 10:49:36.499757
70	VCH-12-20260330104936-3	1000.00	2026-03-30 10:49:36.499757	2026-04-29 10:49:36.499757	VMS|VOUCHER|VCH-12-20260330104936-3	issued	16	\N	2026-03-30 10:49:36.499757	2026-03-30 10:49:36.499757
71	VCH-12-20260330104936-4	1000.00	2026-03-30 10:49:36.499757	2026-04-29 10:49:36.499757	VMS|VOUCHER|VCH-12-20260330104936-4	issued	16	\N	2026-03-30 10:49:36.499757	2026-03-30 10:49:36.499757
72	VCH-12-20260330104936-5	1000.00	2026-03-30 10:49:36.499757	2026-04-29 10:49:36.499757	VMS|VOUCHER|VCH-12-20260330104936-5	issued	16	\N	2026-03-30 10:49:36.499757	2026-03-30 10:49:36.499757
59	VCH-10-20260330104100-2	3000.00	2026-03-30 10:41:00.103882	2026-06-28 10:41:00.103882	VMS|VOUCHER|VCH-10-20260330104100-2	issued	12	\N	2026-03-30 10:41:00.103882	2026-03-30 10:41:00.103882
60	VCH-10-20260330104100-3	3000.00	2026-03-30 10:41:00.103882	2026-06-28 10:41:00.103882	VMS|VOUCHER|VCH-10-20260330104100-3	issued	12	\N	2026-03-30 10:41:00.103882	2026-03-30 10:41:00.103882
61	VCH-10-20260330104100-4	3000.00	2026-03-30 10:41:00.103882	2026-06-28 10:41:00.103882	VMS|VOUCHER|VCH-10-20260330104100-4	issued	12	\N	2026-03-30 10:41:00.103882	2026-03-30 10:41:00.103882
62	VCH-10-20260330104100-5	3000.00	2026-03-30 10:41:00.103882	2026-06-28 10:41:00.103882	VMS|VOUCHER|VCH-10-20260330104100-5	issued	12	\N	2026-03-30 10:41:00.103882	2026-03-30 10:41:00.103882
63	VCH-10-20260330104100-6	3000.00	2026-03-30 10:41:00.103882	2026-06-28 10:41:00.103882	VMS|VOUCHER|VCH-10-20260330104100-6	issued	12	\N	2026-03-30 10:41:00.103882	2026-03-30 10:41:00.103882
64	VCH-10-20260330104100-7	3000.00	2026-03-30 10:41:00.103882	2026-06-28 10:41:00.103882	VMS|VOUCHER|VCH-10-20260330104100-7	issued	12	\N	2026-03-30 10:41:00.103882	2026-03-30 10:41:00.103882
65	VCH-10-20260330104100-8	3000.00	2026-03-30 10:41:00.103882	2026-06-28 10:41:00.103882	VMS|VOUCHER|VCH-10-20260330104100-8	issued	12	\N	2026-03-30 10:41:00.103882	2026-03-30 10:41:00.103882
66	VCH-10-20260330104100-9	3000.00	2026-03-30 10:41:00.103882	2026-06-28 10:41:00.103882	VMS|VOUCHER|VCH-10-20260330104100-9	issued	12	\N	2026-03-30 10:41:00.103882	2026-03-30 10:41:00.103882
67	VCH-10-20260330104100-10	3000.00	2026-03-30 10:41:00.103882	2026-06-28 10:41:00.103882	VMS|VOUCHER|VCH-10-20260330104100-10	issued	12	\N	2026-03-30 10:41:00.103882	2026-03-30 10:41:00.103882
58	VCH-10-20260330104100-1	3000.00	2026-03-30 10:41:00.103882	2026-06-28 10:41:00.103882	VMS|VOUCHER|VCH-10-20260330104100-1	redeemed	12	\N	2026-03-30 10:41:00.103882	2026-03-30 11:04:54.525572
53	VCH-13-20260330101241-1	5000.00	2026-03-30 10:12:41.305676	2026-08-17 10:12:41.305676	VMS|VOUCHER|VCH-13-20260330101241-1	issued	17	\N	2026-03-30 10:12:41.305676	2026-03-30 10:12:41.305676
54	VCH-13-20260330101241-2	5000.00	2026-03-30 10:12:41.305676	2026-08-17 10:12:41.305676	VMS|VOUCHER|VCH-13-20260330101241-2	issued	17	\N	2026-03-30 10:12:41.305676	2026-03-30 10:12:41.305676
55	VCH-13-20260330101241-3	5000.00	2026-03-30 10:12:41.305676	2026-08-17 10:12:41.305676	VMS|VOUCHER|VCH-13-20260330101241-3	issued	17	\N	2026-03-30 10:12:41.305676	2026-03-30 10:12:41.305676
56	VCH-13-20260330101241-4	5000.00	2026-03-30 10:12:41.305676	2026-08-17 10:12:41.305676	VMS|VOUCHER|VCH-13-20260330101241-4	issued	17	\N	2026-03-30 10:12:41.305676	2026-03-30 10:12:41.305676
57	VCH-13-20260330101241-5	5000.00	2026-03-30 10:12:41.305676	2026-08-17 10:12:41.305676	VMS|VOUCHER|VCH-13-20260330101241-5	issued	17	\N	2026-03-30 10:12:41.305676	2026-03-30 10:12:41.305676
52	VCH-14-20260312234832-5	500.00	2026-03-12 23:48:32.759972	2026-06-20 23:48:32.759972	VMS|VOUCHER|VCH-14-20260312234832-5	issued	19	\N	2026-03-12 23:48:32.759972	2026-03-12 23:48:32.759972
40	VCH-4-20260220180728-3	1000.00	2026-02-20 18:07:28.236601	2026-05-31 18:07:28.236601	VMS|VOUCHER|VCH-4-20260220180728-3	issued	9	\N	2026-02-20 18:07:28.236601	2026-02-20 18:07:28.236601
41	VCH-4-20260220180728-4	1000.00	2026-02-20 18:07:28.236601	2026-05-31 18:07:28.236601	VMS|VOUCHER|VCH-4-20260220180728-4	issued	9	\N	2026-02-20 18:07:28.236601	2026-02-20 18:07:28.236601
42	VCH-4-20260220180728-5	1000.00	2026-02-20 18:07:28.236601	2026-05-31 18:07:28.236601	VMS|VOUCHER|VCH-4-20260220180728-5	issued	9	\N	2026-02-20 18:07:28.236601	2026-02-20 18:07:28.236601
43	VCH-4-20260220180728-6	1000.00	2026-02-20 18:07:28.236601	2026-05-31 18:07:28.236601	VMS|VOUCHER|VCH-4-20260220180728-6	issued	9	\N	2026-02-20 18:07:28.236601	2026-02-20 18:07:28.236601
44	VCH-4-20260220180728-7	1000.00	2026-02-20 18:07:28.236601	2026-05-31 18:07:28.236601	VMS|VOUCHER|VCH-4-20260220180728-7	issued	9	\N	2026-02-20 18:07:28.236601	2026-02-20 18:07:28.236601
45	VCH-4-20260220180728-8	1000.00	2026-02-20 18:07:28.236601	2026-05-31 18:07:28.236601	VMS|VOUCHER|VCH-4-20260220180728-8	issued	9	\N	2026-02-20 18:07:28.236601	2026-02-20 18:07:28.236601
46	VCH-4-20260220180728-9	1000.00	2026-02-20 18:07:28.236601	2026-05-31 18:07:28.236601	VMS|VOUCHER|VCH-4-20260220180728-9	issued	9	\N	2026-02-20 18:07:28.236601	2026-02-20 18:07:28.236601
38	VCH-4-20260220180728-1	1000.00	2026-02-20 18:07:28.236601	2026-05-31 18:07:28.236601	VMS|VOUCHER|VCH-4-20260220180728-1	redeemed	9	\N	2026-02-20 18:07:28.236601	2026-03-30 11:06:49.565277
47	VCH-4-20260220180728-10	1000.00	2026-02-20 18:07:28.236601	2026-05-31 18:07:28.236601	VMS|VOUCHER|VCH-4-20260220180728-10	redeemed	9	\N	2026-02-20 18:07:28.236601	2026-03-30 11:19:54.833146
14	VCH-5-20260128120059-1	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-1	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
15	VCH-5-20260128120059-2	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-2	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
16	VCH-5-20260128120059-3	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-3	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
17	VCH-5-20260128120059-4	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-4	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
18	VCH-5-20260128120059-5	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-5	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
19	VCH-5-20260128120059-6	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-6	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
20	VCH-5-20260128120059-7	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-7	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
21	VCH-5-20260128120059-8	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-8	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
22	VCH-5-20260128120059-9	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-9	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
23	VCH-5-20260128120059-10	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-10	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
24	VCH-5-20260128120059-11	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-11	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
25	VCH-5-20260128120059-12	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-12	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
26	VCH-5-20260128120059-13	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-13	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
27	VCH-5-20260128120059-14	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-14	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
28	VCH-5-20260128120059-15	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-15	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
29	VCH-5-20260128120059-16	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-16	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
30	VCH-5-20260128120059-17	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-17	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
31	VCH-5-20260128120059-18	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-18	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
32	VCH-5-20260128120059-19	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-19	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
33	VCH-5-20260128120059-20	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-20	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
34	VCH-5-20260128120059-21	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-21	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
35	VCH-5-20260128120059-22	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-22	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
36	VCH-5-20260128120059-23	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-23	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
37	VCH-5-20260128120059-24	2000.00	2026-01-28 12:00:59.40579	2026-05-08 12:00:59.40579	VMS|VOUCHER|VCH-5-20260128120059-24	issued	10	\N	2026-01-28 12:00:59.40579	2026-01-28 12:00:59.40579
73	VCH-17-20260421001153-1	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-1	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
74	VCH-17-20260421001153-2	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-2	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
75	VCH-17-20260421001153-3	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-3	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
76	VCH-17-20260421001153-4	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-4	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
77	VCH-17-20260421001153-5	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-5	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
78	VCH-17-20260421001153-6	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-6	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
79	VCH-17-20260421001153-7	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-7	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
80	VCH-17-20260421001153-8	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-8	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
81	VCH-17-20260421001153-9	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-9	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
82	VCH-17-20260421001153-10	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-10	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
83	VCH-17-20260421001153-11	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-11	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
84	VCH-17-20260421001153-12	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-12	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
85	VCH-17-20260421001153-13	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-13	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
86	VCH-17-20260421001153-14	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-14	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
87	VCH-17-20260421001153-15	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-15	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
88	VCH-17-20260421001153-16	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-16	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
89	VCH-17-20260421001153-17	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-17	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
90	VCH-17-20260421001153-18	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-18	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
91	VCH-17-20260421001153-19	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-19	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
92	VCH-17-20260421001153-20	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-20	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
93	VCH-17-20260421001153-21	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-21	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
94	VCH-17-20260421001153-22	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-22	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
95	VCH-17-20260421001153-23	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-23	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
96	VCH-17-20260421001153-24	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-24	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
97	VCH-17-20260421001153-25	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-25	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
98	VCH-17-20260421001153-26	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-26	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
99	VCH-17-20260421001153-27	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-27	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
100	VCH-17-20260421001153-28	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-28	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
101	VCH-17-20260421001153-29	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-29	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
102	VCH-17-20260421001153-30	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-30	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
103	VCH-17-20260421001153-31	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-31	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
104	VCH-17-20260421001153-32	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-32	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
105	VCH-17-20260421001153-33	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-33	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
106	VCH-17-20260421001153-34	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-34	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
107	VCH-17-20260421001153-35	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-35	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
108	VCH-17-20260421001153-36	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-36	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
109	VCH-17-20260421001153-37	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-37	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
110	VCH-17-20260421001153-38	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-38	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
111	VCH-17-20260421001153-39	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-39	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
112	VCH-17-20260421001153-40	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-40	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
113	VCH-17-20260421001153-41	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-41	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
114	VCH-17-20260421001153-42	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-42	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
115	VCH-17-20260421001153-43	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-43	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
116	VCH-17-20260421001153-44	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-44	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
117	VCH-17-20260421001153-45	5000.00	2026-04-21 00:11:53.769888	2026-06-20 00:11:53.769888	VMS|VOUCHER|VCH-17-20260421001153-45	issued	21	17	2026-04-21 00:11:53.769888	2026-04-21 00:11:53.769888
\.


--
-- Data for Name: voucher_action_log; Type: TABLE DATA; Schema: vms; Owner: vmsproject
--

COPY vms.voucher_action_log (action_id, voucher_id, action, performed_by, performed_at, details) FROM stdin;
\.


--
-- Data for Name: voucher_audit; Type: TABLE DATA; Schema: vms; Owner: vmsproject
--

COPY vms.voucher_audit (audit_id, ref_voucher, no_voucher, ancien_statut, nouveau_statut, action, user_id, audit_date, ip_address, details) FROM stdin;
\.


--
-- Name: permissions_id_seq; Type: SEQUENCE SET; Schema: public; Owner: vmsproject
--

SELECT pg_catalog.setval('public.permissions_id_seq', 22, true);


--
-- Name: roles_id_seq; Type: SEQUENCE SET; Schema: public; Owner: vmsproject
--

SELECT pg_catalog.setval('public.roles_id_seq', 12, true);


--
-- Name: users_id_seq; Type: SEQUENCE SET; Schema: public; Owner: vmsproject
--

SELECT pg_catalog.setval('public.users_id_seq', 12, true);


--
-- Name: voucher_usage_id_seq; Type: SEQUENCE SET; Schema: public; Owner: vmsproject
--

SELECT pg_catalog.setval('public.voucher_usage_id_seq', 1, false);


--
-- Name: vouchers_id_seq; Type: SEQUENCE SET; Schema: public; Owner: vmsproject
--

SELECT pg_catalog.setval('public.vouchers_id_seq', 4, true);


--
-- Name: client_ref_client_seq; Type: SEQUENCE SET; Schema: vms; Owner: vmsproject
--

SELECT pg_catalog.setval('vms.client_ref_client_seq', 21, true);


--
-- Name: demande_ref_demande_seq; Type: SEQUENCE SET; Schema: vms; Owner: vmsproject
--

SELECT pg_catalog.setval('vms.demande_ref_demande_seq', 17, true);


--
-- Name: login_logs_log_id_seq; Type: SEQUENCE SET; Schema: vms; Owner: vmsproject
--

SELECT pg_catalog.setval('vms.login_logs_log_id_seq', 34, true);


--
-- Name: magasin_magasin_id_seq; Type: SEQUENCE SET; Schema: vms; Owner: vmsproject
--

SELECT pg_catalog.setval('vms.magasin_magasin_id_seq', 4, true);


--
-- Name: redemption_logs_log_id_seq; Type: SEQUENCE SET; Schema: vms; Owner: vmsproject
--

SELECT pg_catalog.setval('vms.redemption_logs_log_id_seq', 7, true);


--
-- Name: redemption_ref_redemption_seq; Type: SEQUENCE SET; Schema: vms; Owner: vmsproject
--

SELECT pg_catalog.setval('vms.redemption_ref_redemption_seq', 8, true);


--
-- Name: user_permissions_permission_id_seq; Type: SEQUENCE SET; Schema: vms; Owner: vmsproject
--

SELECT pg_catalog.setval('vms.user_permissions_permission_id_seq', 9, true);


--
-- Name: users_user_id_seq; Type: SEQUENCE SET; Schema: vms; Owner: vmsproject
--

SELECT pg_catalog.setval('vms.users_user_id_seq', 11, true);


--
-- Name: voucher_action_log_action_id_seq; Type: SEQUENCE SET; Schema: vms; Owner: vmsproject
--

SELECT pg_catalog.setval('vms.voucher_action_log_action_id_seq', 1, false);


--
-- Name: voucher_audit_audit_id_seq; Type: SEQUENCE SET; Schema: vms; Owner: vmsproject
--

SELECT pg_catalog.setval('vms.voucher_audit_audit_id_seq', 1, false);


--
-- Name: voucher_ref_voucher_seq; Type: SEQUENCE SET; Schema: vms; Owner: vmsproject
--

SELECT pg_catalog.setval('vms.voucher_ref_voucher_seq', 117, true);


--
-- Name: permissions permissions_name_key; Type: CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.permissions
    ADD CONSTRAINT permissions_name_key UNIQUE (name);


--
-- Name: permissions permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.permissions
    ADD CONSTRAINT permissions_pkey PRIMARY KEY (id);


--
-- Name: role_permissions role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (role_id, permission_id);


--
-- Name: roles roles_name_key; Type: CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_name_key UNIQUE (name);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: users users_username_key; Type: CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_username_key UNIQUE (username);


--
-- Name: voucher_usage voucher_usage_pkey; Type: CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.voucher_usage
    ADD CONSTRAINT voucher_usage_pkey PRIMARY KEY (id);


--
-- Name: vouchers vouchers_code_key; Type: CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.vouchers
    ADD CONSTRAINT vouchers_code_key UNIQUE (code);


--
-- Name: vouchers vouchers_pkey; Type: CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.vouchers
    ADD CONSTRAINT vouchers_pkey PRIMARY KEY (id);


--
-- Name: client client_email_key; Type: CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.client
    ADD CONSTRAINT client_email_key UNIQUE (email);


--
-- Name: client client_pkey; Type: CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.client
    ADD CONSTRAINT client_pkey PRIMARY KEY (ref_client);


--
-- Name: demande demande_pkey; Type: CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.demande
    ADD CONSTRAINT demande_pkey PRIMARY KEY (ref_demande);


--
-- Name: login_logs login_logs_pkey; Type: CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.login_logs
    ADD CONSTRAINT login_logs_pkey PRIMARY KEY (log_id);


--
-- Name: magasin magasin_pkey; Type: CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.magasin
    ADD CONSTRAINT magasin_pkey PRIMARY KEY (magasin_id);


--
-- Name: redemption_logs redemption_logs_pkey; Type: CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.redemption_logs
    ADD CONSTRAINT redemption_logs_pkey PRIMARY KEY (log_id);


--
-- Name: redemption redemption_pkey; Type: CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.redemption
    ADD CONSTRAINT redemption_pkey PRIMARY KEY (ref_redemption);


--
-- Name: user_permissions uq_user_permissions; Type: CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.user_permissions
    ADD CONSTRAINT uq_user_permissions UNIQUE (user_id);


--
-- Name: user_permissions user_permissions_pkey; Type: CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.user_permissions
    ADD CONSTRAINT user_permissions_pkey PRIMARY KEY (permission_id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (user_id);


--
-- Name: users users_username_key; Type: CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.users
    ADD CONSTRAINT users_username_key UNIQUE (username);


--
-- Name: voucher_action_log voucher_action_log_pkey; Type: CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.voucher_action_log
    ADD CONSTRAINT voucher_action_log_pkey PRIMARY KEY (action_id);


--
-- Name: voucher_audit voucher_audit_pkey; Type: CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.voucher_audit
    ADD CONSTRAINT voucher_audit_pkey PRIMARY KEY (audit_id);


--
-- Name: voucher voucher_no_voucher_key; Type: CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.voucher
    ADD CONSTRAINT voucher_no_voucher_key UNIQUE (no_voucher);


--
-- Name: voucher voucher_pkey; Type: CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.voucher
    ADD CONSTRAINT voucher_pkey PRIMARY KEY (ref_voucher);


--
-- Name: idx_client_email; Type: INDEX; Schema: vms; Owner: vmsproject
--

CREATE INDEX idx_client_email ON vms.client USING btree (email);


--
-- Name: idx_demande_statut; Type: INDEX; Schema: vms; Owner: vmsproject
--

CREATE INDEX idx_demande_statut ON vms.demande USING btree (statut);


--
-- Name: idx_redemption_logs_date; Type: INDEX; Schema: vms; Owner: vmsproject
--

CREATE INDEX idx_redemption_logs_date ON vms.redemption_logs USING btree (log_date DESC);


--
-- Name: idx_redemption_logs_magasin; Type: INDEX; Schema: vms; Owner: vmsproject
--

CREATE INDEX idx_redemption_logs_magasin ON vms.redemption_logs USING btree (magasin_id);


--
-- Name: idx_redemption_logs_statut; Type: INDEX; Schema: vms; Owner: vmsproject
--

CREATE INDEX idx_redemption_logs_statut ON vms.redemption_logs USING btree (statut);


--
-- Name: idx_redemption_logs_voucher; Type: INDEX; Schema: vms; Owner: vmsproject
--

CREATE INDEX idx_redemption_logs_voucher ON vms.redemption_logs USING btree (ref_voucher);


--
-- Name: idx_users_username; Type: INDEX; Schema: vms; Owner: vmsproject
--

CREATE INDEX idx_users_username ON vms.users USING btree (username);


--
-- Name: idx_voucher_status; Type: INDEX; Schema: vms; Owner: vmsproject
--

CREATE INDEX idx_voucher_status ON vms.voucher USING btree (status_vouch);


--
-- Name: redemption redem_log_trigger; Type: TRIGGER; Schema: vms; Owner: vmsproject
--

CREATE TRIGGER redem_log_trigger AFTER INSERT ON vms.redemption FOR EACH ROW EXECUTE FUNCTION vms.fn_redem_log();


--
-- Name: TRIGGER redem_log_trigger ON redemption; Type: COMMENT; Schema: vms; Owner: vmsproject
--

COMMENT ON TRIGGER redem_log_trigger ON vms.redemption IS 'Déclenché après chaque INSERT dans vms.redemption. Enregistre succès ET échecs dans vms.redemption_logs.';


--
-- Name: voucher trg_auto_expire_voucher; Type: TRIGGER; Schema: vms; Owner: vmsproject
--

CREATE TRIGGER trg_auto_expire_voucher BEFORE INSERT OR UPDATE ON vms.voucher FOR EACH ROW EXECUTE FUNCTION vms.update_expired_vouchers();


--
-- Name: voucher trg_check_voucher_redemption; Type: TRIGGER; Schema: vms; Owner: vmsproject
--

CREATE TRIGGER trg_check_voucher_redemption BEFORE UPDATE OF status_vouch ON vms.voucher FOR EACH ROW WHEN ((new.status_vouch = 'redeemed'::vms.voucher_status)) EXECUTE FUNCTION public.check_voucher_before_redemption();


--
-- Name: users trg_login_log; Type: TRIGGER; Schema: vms; Owner: vmsproject
--

CREATE TRIGGER trg_login_log AFTER UPDATE OF ddl ON vms.users FOR EACH ROW EXECUTE FUNCTION vms.log_login_attempt();


--
-- Name: role_permissions role_permissions_permission_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES public.permissions(id) ON DELETE CASCADE;


--
-- Name: role_permissions role_permissions_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE;


--
-- Name: users users_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id);


--
-- Name: voucher_usage voucher_usage_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.voucher_usage
    ADD CONSTRAINT voucher_usage_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: voucher_usage voucher_usage_voucher_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.voucher_usage
    ADD CONSTRAINT voucher_usage_voucher_id_fkey FOREIGN KEY (voucher_id) REFERENCES public.vouchers(id) ON DELETE CASCADE;


--
-- Name: vouchers vouchers_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: vmsproject
--

ALTER TABLE ONLY public.vouchers
    ADD CONSTRAINT vouchers_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: demande demande_approved_by_fkey; Type: FK CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.demande
    ADD CONSTRAINT demande_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES vms.users(user_id) ON DELETE SET NULL;


--
-- Name: demande demande_client_id_fkey; Type: FK CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.demande
    ADD CONSTRAINT demande_client_id_fkey FOREIGN KEY (client_id) REFERENCES vms.client(ref_client) ON DELETE CASCADE;


--
-- Name: demande demande_initiated_by_fkey; Type: FK CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.demande
    ADD CONSTRAINT demande_initiated_by_fkey FOREIGN KEY (initiated_by) REFERENCES vms.users(user_id) ON DELETE SET NULL;


--
-- Name: demande demande_paid_by_fkey; Type: FK CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.demande
    ADD CONSTRAINT demande_paid_by_fkey FOREIGN KEY (paid_by) REFERENCES vms.users(user_id) ON DELETE SET NULL;


--
-- Name: redemption_logs redemption_logs_magasin_id_fkey; Type: FK CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.redemption_logs
    ADD CONSTRAINT redemption_logs_magasin_id_fkey FOREIGN KEY (magasin_id) REFERENCES vms.magasin(magasin_id) ON DELETE SET NULL;


--
-- Name: redemption_logs redemption_logs_redeemed_by_fkey; Type: FK CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.redemption_logs
    ADD CONSTRAINT redemption_logs_redeemed_by_fkey FOREIGN KEY (redeemed_by) REFERENCES vms.users(user_id) ON DELETE SET NULL;


--
-- Name: redemption_logs redemption_logs_ref_voucher_fkey; Type: FK CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.redemption_logs
    ADD CONSTRAINT redemption_logs_ref_voucher_fkey FOREIGN KEY (ref_voucher) REFERENCES vms.voucher(ref_voucher) ON DELETE SET NULL;


--
-- Name: redemption redemption_magasin_id_fkey; Type: FK CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.redemption
    ADD CONSTRAINT redemption_magasin_id_fkey FOREIGN KEY (magasin_id) REFERENCES vms.magasin(magasin_id);


--
-- Name: redemption redemption_redeemed_by_fkey; Type: FK CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.redemption
    ADD CONSTRAINT redemption_redeemed_by_fkey FOREIGN KEY (redeemed_by) REFERENCES vms.users(user_id);


--
-- Name: redemption redemption_ref_voucher_fkey; Type: FK CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.redemption
    ADD CONSTRAINT redemption_ref_voucher_fkey FOREIGN KEY (ref_voucher) REFERENCES vms.voucher(ref_voucher);


--
-- Name: user_permissions user_permissions_user_id_fkey; Type: FK CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.user_permissions
    ADD CONSTRAINT user_permissions_user_id_fkey FOREIGN KEY (user_id) REFERENCES vms.users(user_id) ON DELETE CASCADE;


--
-- Name: voucher_action_log voucher_action_log_performed_by_fkey; Type: FK CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.voucher_action_log
    ADD CONSTRAINT voucher_action_log_performed_by_fkey FOREIGN KEY (performed_by) REFERENCES vms.users(user_id) ON DELETE SET NULL;


--
-- Name: voucher_action_log voucher_action_log_voucher_id_fkey; Type: FK CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.voucher_action_log
    ADD CONSTRAINT voucher_action_log_voucher_id_fkey FOREIGN KEY (voucher_id) REFERENCES vms.voucher(ref_voucher) ON DELETE CASCADE;


--
-- Name: voucher voucher_client_id_fkey; Type: FK CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.voucher
    ADD CONSTRAINT voucher_client_id_fkey FOREIGN KEY (client_id) REFERENCES vms.client(ref_client) ON DELETE SET NULL;


--
-- Name: voucher voucher_demande_id_fkey; Type: FK CONSTRAINT; Schema: vms; Owner: vmsproject
--

ALTER TABLE ONLY vms.voucher
    ADD CONSTRAINT voucher_demande_id_fkey FOREIGN KEY (ref_demande) REFERENCES vms.demande(ref_demande) ON DELETE SET NULL;


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: vmsproject
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: vmsproject
--

ALTER DEFAULT PRIVILEGES FOR ROLE vmsproject IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO vmsproject;


--
-- PostgreSQL database dump complete
--

\unrestrict FmQc9AG46FCbo8mrbeRxLH5BFd83Th17wRHsd08rAFNc2Mgqc5rgpB9XHhZ5iKZ

